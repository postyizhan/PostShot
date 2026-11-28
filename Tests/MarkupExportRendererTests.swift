// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreGraphics
import SwiftUI
import XCTest
@testable import PostShot

/// Validates `MarkupExportRenderer` fast-path, strokes, text stickers, corner clipping, and shadow padding.
final class MarkupExportRendererTests: XCTestCase {

    // MARK: - Synthetic Helpers

    private func makeSolidImage(
        width: Int,
        height: Int,
        r: UInt8 = 255,
        g: UInt8 = 255,
        b: UInt8 = 255,
        a: UInt8 = 255
    ) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for idx in stride(from: 0, to: pixels.count, by: 4) {
            pixels[idx] = r
            pixels[idx + 1] = g
            pixels[idx + 2] = b
            pixels[idx + 3] = a
        }
        return makeRGBAImage(pixels: &pixels, width: width, height: height)
    }

    private func makeTopBottomBandedImage(width: Int, height: Int) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let isTop = y < height / 2
            for x in 0..<width {
                let idx = (y * width + x) * 4
                pixels[idx] = isTop ? 255 : 0
                pixels[idx + 1] = 0
                pixels[idx + 2] = isTop ? 0 : 255
                pixels[idx + 3] = 255
            }
        }
        return makeRGBAImage(pixels: &pixels, width: width, height: height)
    }

    private func makeRGBAImage(pixels: inout [UInt8], width: Int, height: Int) -> CGImage {
        pixels.withUnsafeMutableBytes { ptr in
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx = CGContext(
                data: ptr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            return ctx.makeImage()!
        }
    }

    private func pixelRGBA(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { ptr in
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx = CGContext(
                data: ptr.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let idx = (y * image.width + x) * 4
        return (pixels[idx], pixels[idx + 1], pixels[idx + 2], pixels[idx + 3])
    }

    private func plainMarkupState() -> EditorMarkupState {
        var markup = EditorMarkupState()
        markup.beautifyCornerRadius = 0
        markup.beautifyShadow = false
        markup.beautifyFrame = false
        return markup
    }

    // MARK: - Tests

    func testFastPathReturnsUnchangedImageWhenNothingEnabled() {
        let base = makeSolidImage(width: 360, height: 480, r: 20, g: 120, b: 220)
        let markup = plainMarkupState()

        XCTAssertFalse(MarkupExportRenderer.needsRendering(for: markup))
        let output = MarkupExportRenderer.render(baseImage: base, markup: markup)
        XCTAssertEqual(output.width, base.width)
        XCTAssertEqual(output.height, base.height)
        XCTAssertTrue(output === base)
    }

    func testOrientationPreservedInTopDownRender() {
        let base = makeTopBottomBandedImage(width: 360, height: 400)
        var markup = plainMarkupState()
        markup.beautifyFrame = true

        let output = MarkupExportRenderer.render(baseImage: base, markup: markup)
        let topPixel = pixelRGBA(output, x: 180, y: 80)
        let bottomPixel = pixelRGBA(output, x: 180, y: 320)

        XCTAssertGreaterThan(topPixel.r, 240)
        XCTAssertLessThan(topPixel.b, 15)
        XCTAssertLessThan(bottomPixel.r, 15)
        XCTAssertGreaterThan(bottomPixel.b, 240)
    }

    func testRedPenStrokeMutatesPixelsAlongStrokePath() {
        let base = makeSolidImage(width: 360, height: 480)
        var markup = plainMarkupState()
        markup.appendStroke(MarkupStroke(
            points: [CGPoint(x: 0.2, y: 0.5), CGPoint(x: 0.8, y: 0.5)],
            color: .red,
            lineWidthFraction: 10.0 / 360.0,
            opacity: 1.0,
            brushStyle: .pen
        ))

        XCTAssertTrue(MarkupExportRenderer.needsRendering(for: markup))
        let output = MarkupExportRenderer.render(baseImage: base, markup: markup)
        XCTAssertEqual(output.width, 360)
        XCTAssertEqual(output.height, 480)

        let onStroke = pixelRGBA(output, x: 180, y: 240)
        XCTAssertGreaterThan(onStroke.r, 200)
        XCTAssertLessThan(onStroke.g, 80)
        XCTAssertLessThan(onStroke.b, 80)

        let offStroke = pixelRGBA(output, x: 180, y: 40)
        XCTAssertEqual(offStroke.r, 255)
        XCTAssertEqual(offStroke.g, 255)
        XCTAssertEqual(offStroke.b, 255)
    }

    func testArrowRectAndMosaicStrokesRenderExpectedPixels() {
        let base = makeSolidImage(width: 360, height: 480)
        var markup = plainMarkupState()
        markup.appendStroke(MarkupStroke(
            points: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.2)],
            color: .blue,
            lineWidthFraction: 8.0 / 360.0,
            opacity: 1.0,
            brushStyle: .arrow
        ))
        markup.appendStroke(MarkupStroke(
            points: [CGPoint(x: 0.3, y: 0.4), CGPoint(x: 0.7, y: 0.6)],
            color: .green,
            lineWidthFraction: 8.0 / 360.0,
            opacity: 1.0,
            brushStyle: .rect
        ))
        markup.appendStroke(MarkupStroke(
            points: [CGPoint(x: 0.5, y: 0.8)],
            color: Color(white: 0.78),
            lineWidthFraction: 22.0 / 360.0,
            opacity: 0.92,
            brushStyle: .pen,
            redactStyle: .mosaic
        ))

        let output = MarkupExportRenderer.render(baseImage: base, markup: markup)
        let arrowPixel = pixelRGBA(output, x: 180, y: 96)
        XCTAssertGreaterThan(arrowPixel.b, 180)
        XCTAssertLessThan(arrowPixel.r, 80)

        let rectTopEdge = pixelRGBA(output, x: 180, y: 192)
        XCTAssertGreaterThan(rectTopEdge.g, 150)
        XCTAssertLessThan(rectTopEdge.r, 100)

        let mosaicPixel = pixelRGBA(output, x: 180, y: 384)
        XCTAssertLessThan(mosaicPixel.r, 220)
    }

    func testTextStickerRendersVisiblePixelsAroundCenter() {
        let base = makeSolidImage(width: 360, height: 480)
        var markup = plainMarkupState()
        markup.textColor = .white
        markup.textHasBackground = true
        markup.addSticker(text: "TEST", normalizedCenter: CGPoint(x: 0.5, y: 0.5))

        let output = MarkupExportRenderer.render(baseImage: base, markup: markup)
        var mutatedCount = 0
        for y in 225...255 {
            for x in 160...200 {
                let p = pixelRGBA(output, x: x, y: y)
                if p.r < 240 || p.g < 240 || p.b < 240 {
                    mutatedCount += 1
                }
            }
        }
        XCTAssertGreaterThan(mutatedCount, 50)

        let corner = pixelRGBA(output, x: 10, y: 10)
        XCTAssertEqual(corner.r, 255)
        XCTAssertEqual(corner.g, 255)
        XCTAssertEqual(corner.b, 255)
    }

    func testCornerRadiusWithoutShadowClipsCornersTransparent() {
        let base = makeSolidImage(width: 360, height: 360, r: 30, g: 100, b: 220)
        var markup = plainMarkupState()
        markup.beautifyCornerRadius = 20

        let output = MarkupExportRenderer.render(baseImage: base, markup: markup)
        XCTAssertEqual(output.width, 360)
        XCTAssertEqual(output.height, 360)

        let corner = pixelRGBA(output, x: 0, y: 0)
        XCTAssertEqual(corner.a, 0)

        let center = pixelRGBA(output, x: 180, y: 180)
        XCTAssertEqual(center.a, 255)
        XCTAssertEqual(center.r, 30)
        XCTAssertEqual(center.g, 100)
        XCTAssertEqual(center.b, 220)
    }

    func testBeautifyShadowExpandsDimensionsWithWhitePaddingAndClipsCorners() {
        let base = makeSolidImage(width: 360, height: 360, r: 30, g: 100, b: 220)
        var markup = plainMarkupState()
        markup.beautifyCornerRadius = 20
        markup.beautifyShadow = true

        let expectedPad = max(24, Int((CGFloat(base.width) * 0.04).rounded()))
        let output = MarkupExportRenderer.render(baseImage: base, markup: markup)
        XCTAssertEqual(output.width, 360 + expectedPad * 2)
        XCTAssertEqual(output.height, 360 + expectedPad * 2)

        let outerCorner = pixelRGBA(output, x: 0, y: 0)
        XCTAssertGreaterThanOrEqual(outerCorner.r, 245)
        XCTAssertGreaterThanOrEqual(outerCorner.g, 245)
        XCTAssertGreaterThanOrEqual(outerCorner.b, 245)
        XCTAssertEqual(outerCorner.a, 255)

        let clippedImageCorner = pixelRGBA(output, x: expectedPad, y: expectedPad)
        XCTAssertGreaterThan(clippedImageCorner.r, 150)

        let center = pixelRGBA(output, x: output.width / 2, y: output.height / 2)
        XCTAssertEqual(center.r, 30)
        XCTAssertEqual(center.g, 100)
        XCTAssertEqual(center.b, 220)
        XCTAssertEqual(center.a, 255)
    }

    func testBeautifyShadowCastsBelowCardAndRenderOrThrowSucceeds() throws {
        let base = makeSolidImage(width: 360, height: 360, r: 30, g: 100, b: 220)
        var markup = plainMarkupState()
        markup.beautifyCornerRadius = 12
        markup.beautifyShadow = true

        let expectedPad = max(24, Int((CGFloat(base.width) * 0.04).rounded()))
        let output = try MarkupExportRenderer.renderOrThrow(baseImage: base, markup: markup)

        let topPadPixel = pixelRGBA(output, x: output.width / 2, y: expectedPad - 4)
        let bottomPadPixel = pixelRGBA(output, x: output.width / 2, y: output.height - expectedPad + 4)
        let topLuma = Int(topPadPixel.r) + Int(topPadPixel.g) + Int(topPadPixel.b)
        let bottomLuma = Int(bottomPadPixel.r) + Int(bottomPadPixel.g) + Int(bottomPadPixel.b)
        XCTAssertLessThan(bottomLuma, topLuma, "Shadow should fall below the card, making bottom padding darker than top padding")
    }
}
