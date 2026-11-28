// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreGraphics
import Foundation
import SwiftUI
import UIKit

/// Renders non-destructive markup strokes, text stickers, and beautify styling onto a `CGImage`.
enum MarkupExportRenderer {

    enum RenderError: LocalizedError {
        case canvasTooLarge
        case contextCreationFailed

        var errorDescription: String? {
            switch self {
            case .canvasTooLarge:
                return "导出图像尺寸过大，超出渲染内存上限。"
            case .contextCreationFailed:
                return "无法创建图像渲染上下文，请重试。"
            }
        }
    }

    private static let maxBitmapBytes: Int64 = 256 * 1024 * 1024

    /// Returns `true` when any annotation or beautify option would alter the base image.
    static func needsRendering(for markup: EditorMarkupState) -> Bool {
        markup.hasActiveAnnotations
            || markup.beautifyCornerRadius > 0
            || markup.beautifyShadow
            || markup.beautifyFrame
    }

    /// Renders `markup` onto `baseImage`, returning `baseImage` unchanged on fast-path or render failure.
    static func render(baseImage: CGImage, markup: EditorMarkupState) -> CGImage {
        (try? renderOrThrow(baseImage: baseImage, markup: markup)) ?? baseImage
    }

    /// Renders `markup` onto `baseImage`, throwing `RenderError` if canvas allocation or context creation fails.
    static func renderOrThrow(baseImage: CGImage, markup: EditorMarkupState) throws -> CGImage {
        guard needsRendering(for: markup) else { return baseImage }

        let baseW = baseImage.width, baseH = baseImage.height
        guard baseW > 0, baseH > 0 else { throw RenderError.contextCreationFailed }

        let scale = CGFloat(baseW) / EditorMarkupState.referenceWidth
        let pad = markup.beautifyShadow ? max(24, Int((CGFloat(baseW) * 0.04).rounded())) : 0
        let canvasW = baseW + pad * 2, canvasH = baseH + pad * 2
        let (byteCount, overflow) = Int64(canvasW).multipliedReportingOverflow(by: Int64(canvasH) * 4)
        guard canvasW > 0, canvasH > 0, !overflow, byteCount > 0, byteCount <= maxBitmapBytes else {
            throw RenderError.canvasTooLarge
        }
        guard let ctx = makeContext(width: canvasW, height: canvasH) else { throw RenderError.contextCreationFailed }

        if markup.beautifyShadow {
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
        }
        ctx.translateBy(x: 0, y: CGFloat(canvasH)); ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }

        let imageRect = CGRect(x: CGFloat(pad), y: CGFloat(pad), width: CGFloat(baseW), height: CGFloat(baseH))
        let radius = EditorMarkupState.scaledCornerRadius(markup.beautifyCornerRadius, for: imageRect.size)
        let roundedPath = UIBezierPath(roundedRect: imageRect, cornerRadius: radius).cgPath

        drawShadowIfNeeded(markup, roundedPath: roundedPath, scale: scale, in: ctx)
        ctx.saveGState(); ctx.addPath(roundedPath); ctx.clip()
        UIImage(cgImage: baseImage).draw(in: imageRect)
        for stroke in markup.strokes { drawStroke(stroke, in: imageRect, scale: scale, ctx: ctx) }
        for sticker in markup.stickers { drawSticker(sticker, in: imageRect, scale: scale) }
        ctx.restoreGState()

        drawFrameIfNeeded(markup, roundedPath: roundedPath, scale: scale, in: ctx)
        guard let output = ctx.makeImage() else { throw RenderError.contextCreationFailed }
        return output
    }
}

// MARK: - Context & Beautify Helpers

private extension MarkupExportRenderer {

    static func makeContext(width: Int, height: Int) -> CGContext? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    static func drawShadowIfNeeded(
        _ markup: EditorMarkupState,
        roundedPath: CGPath,
        scale: CGFloat,
        in ctx: CGContext
    ) {
        guard markup.beautifyShadow else { return }
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -6 * scale),
            blur: 18 * scale,
            color: UIColor.black.withAlphaComponent(0.14).cgColor
        )
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.addPath(roundedPath)
        ctx.fillPath()
        ctx.restoreGState()
    }

    static func drawFrameIfNeeded(
        _ markup: EditorMarkupState,
        roundedPath: CGPath,
        scale: CGFloat,
        in ctx: CGContext
    ) {
        guard markup.beautifyFrame else { return }
        ctx.saveGState()
        ctx.addPath(roundedPath)
        ctx.setStrokeColor(UIColor.black.withAlphaComponent(0.18).cgColor)
        ctx.setLineWidth(max(2, 2 * scale))
        ctx.strokePath()
        ctx.restoreGState()
    }
}

// MARK: - Stroke & Sticker Drawing

private extension MarkupExportRenderer {

    static func drawStroke(_ stroke: MarkupStroke, in imageRect: CGRect, scale: CGFloat, ctx: CGContext) {
        let pts = stroke.points.map {
            CGPoint(x: imageRect.minX + $0.x * imageRect.width, y: imageRect.minY + $0.y * imageRect.height)
        }
        guard !pts.isEmpty else { return }

        let lineWidth = max(1.5, stroke.lineWidthFraction * max(1, imageRect.width))
        let color = UIColor(stroke.color.opacity(stroke.opacity)).cgColor

        if let redactStyle = stroke.redactStyle {
            if redactStyle == .mosaic {
                drawMosaic(pts, in: imageRect, ctx: ctx)
            } else {
                drawFreehand(pts, lineWidth: lineWidth, color: color, in: ctx)
            }
            return
        }

        switch stroke.brushStyle {
        case .pen, .highlighter:
            drawFreehand(pts, lineWidth: lineWidth, color: color, in: ctx)
        case .arrow:
            drawArrow(pts, lineWidth: lineWidth, color: color, in: ctx)
        case .rect:
            drawRectStroke(pts, lineWidth: lineWidth, scale: scale, color: color, in: ctx)
        }
    }

    static func drawFreehand(_ points: [CGPoint], lineWidth: CGFloat, color: CGColor, in ctx: CGContext) {
        guard let first = points.first else { return }
        let path = CGMutablePath()
        path.move(to: first)
        if points.count == 1 {
            path.addLine(to: CGPoint(x: first.x + 0.5, y: first.y + 0.5))
        } else {
            for point in points.dropFirst() { path.addLine(to: point) }
        }
        strokePath(path, lineWidth: lineWidth, color: color, in: ctx)
    }

    static func drawArrow(_ points: [CGPoint], lineWidth: CGFloat, color: CGColor, in ctx: CGContext) {
        guard let start = points.first else { return }
        let end = points.last ?? start
        let path = CGMutablePath()
        path.move(to: start)
        path.addLine(to: end)

        let angle = atan2(end.y - start.y, end.x - start.x)
        let head = max(12, lineWidth * 3)
        let spread: CGFloat = .pi / 6
        path.move(to: CGPoint(x: end.x - head * cos(angle - spread), y: end.y - head * sin(angle - spread)))
        path.addLine(to: end)
        path.addLine(to: CGPoint(x: end.x - head * cos(angle + spread), y: end.y - head * sin(angle + spread)))
        strokePath(path, lineWidth: lineWidth, color: color, in: ctx)
    }

    static func drawRectStroke(
        _ points: [CGPoint],
        lineWidth: CGFloat,
        scale: CGFloat,
        color: CGColor,
        in ctx: CGContext
    ) {
        guard let start = points.first else { return }
        let end = points.last ?? start
        let rect = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: max(2, abs(end.x - start.x)),
            height: max(2, abs(end.y - start.y))
        )
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 4 * scale).cgPath
        strokePath(path, lineWidth: lineWidth, color: color, in: ctx)
    }

    static func strokePath(_ path: CGPath, lineWidth: CGFloat, color: CGColor, in ctx: CGContext) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.restoreGState()
    }

    static func drawMosaic(_ points: [CGPoint], in imageRect: CGRect, ctx: CGContext) {
        let cell = max(4, imageRect.width * 0.018)
        let light = UIColor(white: 0.72, alpha: 0.9).cgColor
        let dark = UIColor(white: 0.34, alpha: 0.9).cgColor
        ctx.saveGState()
        for point in points {
            let baseCol = Int(floor((point.x - imageRect.minX) / cell))
            let baseRow = Int(floor((point.y - imageRect.minY) / cell))
            for dx in -1...1 {
                for dy in -1...1 {
                    let col = baseCol + dx
                    let row = baseRow + dy
                    let gx = imageRect.minX + CGFloat(col) * cell
                    let gy = imageRect.minY + CGFloat(row) * cell
                    ctx.setFillColor(((col + row) & 1 == 0) ? light : dark)
                    ctx.fill(CGRect(x: gx, y: gy, width: cell, height: cell))
                }
            }
        }
        ctx.restoreGState()
    }

    static func drawSticker(_ sticker: TextSticker, in imageRect: CGRect, scale: CGFloat) {
        let center = CGPoint(
            x: imageRect.minX + sticker.position.x * imageRect.width,
            y: imageRect.minY + sticker.position.y * imageRect.height
        )
        let fontSize = max(11, sticker.fontSizeFraction * imageRect.width)
        let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(sticker.color)
        ]
        let nsText = sticker.text as NSString
        let maxSize = CGSize(width: max(1, imageRect.width * 0.92), height: .greatestFiniteMagnitude)
        let measured = nsText.boundingRect(
            with: maxSize,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs,
            context: nil
        ).integral
        let textRect = CGRect(
            x: center.x - measured.width / 2,
            y: center.y - measured.height / 2,
            width: measured.width,
            height: measured.height
        )
        if sticker.hasBackground {
            let pillRect = textRect.insetBy(dx: -12 * scale, dy: -7 * scale)
            let pillPath = UIBezierPath(roundedRect: pillRect, cornerRadius: 10 * scale)
            UIColor.black.withAlphaComponent(0.68).setFill()
            pillPath.fill()
            UIColor.white.withAlphaComponent(0.2).setStroke()
            pillPath.lineWidth = max(1, scale)
            pillPath.stroke()
        }
        nsText.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil)
    }
}
