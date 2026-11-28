// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// Single freehand, shape, or manual-redaction stroke stored in normalized (`0...1`) image coordinates.
struct MarkupStroke: Identifiable, Equatable {
    let id = UUID()
    /// Normalized `(0...1)` points relative to the image bounds.
    var points: [CGPoint]
    var color: Color
    /// Stroke width as a fraction of the image width (reference width = 360pt).
    var lineWidthFraction: CGFloat
    var opacity: Double
    var brushStyle: DrawBrushStyle = .pen
    var redactStyle: ManualRedactStyle? = nil
}

/// Draggable text annotation stored in normalized (`0...1`) image coordinates.
struct TextSticker: Identifiable, Equatable {
    let id = UUID()
    var text: String
    /// Normalized `(0...1)` center position relative to the image bounds.
    var position: CGPoint
    var color: Color
    var hasBackground: Bool
    /// Font size as a fraction of the image width (reference width = 360pt).
    var fontSizeFraction: CGFloat
}

enum RedactMode: String, CaseIterable {
    case auto, manual

    var title: String { self == .auto ? "自动打码" : "手动打码" }
}

enum ManualRedactStyle: String, CaseIterable {
    case mosaic, blur, solid

    var title: String {
        switch self {
        case .mosaic: return "马赛克"
        case .blur: return "模糊"
        case .solid: return "纯色"
        }
    }
}

enum DrawBrushStyle: String, CaseIterable {
    case pen, highlighter, arrow, rect

    var title: String {
        switch self {
        case .pen: return "钢笔"
        case .highlighter: return "荧光笔"
        case .arrow: return "箭头"
        case .rect: return "方框"
        }
    }

    var systemImage: String {
        switch self {
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .arrow: return "arrow.up.right"
        case .rect: return "rectangle"
        }
    }
}

/// Non-destructive markup, redaction, and beautify parameters for the editor.
struct EditorMarkupState {
    enum AnnotationKind { case stroke, sticker }

    static let referenceWidth: CGFloat = 360

    var strokes: [MarkupStroke] = []
    var stickers: [TextSticker] = []
    var redactMode: RedactMode = .auto
    var autoRedactTargets: Set<String> = ["头像", "昵称"]
    var manualRedactStyle: ManualRedactStyle = .mosaic
    var brushStyle: DrawBrushStyle = .pen
    var brushColor: Color = .red
    var brushWidth: CGFloat = 5
    var textColor: Color = .white
    var textHasBackground: Bool = true
    var beautifyCornerRadius: CGFloat = 0
    var beautifyShadow: Bool = false
    var beautifyFrame: Bool = false

    private var history: [AnnotationKind] = []

    var hasActiveAnnotations: Bool { !strokes.isEmpty || !stickers.isEmpty }

    /// Computes the corner radius scaled to `canvasSize` relative to `referenceWidth` (360pt),
    /// clamped to 45% of the shorter edge to match `MarkupExportRenderer`.
    static func scaledCornerRadius(_ baseRadius: CGFloat, for canvasSize: CGSize) -> CGFloat {
        guard baseRadius > 0, canvasSize.width > 0, canvasSize.height > 0 else { return 0 }
        let scale = canvasSize.width / referenceWidth
        return min(min(canvasSize.width, canvasSize.height) * 0.45, baseRadius * scale)
    }

    func hasMarkupChanges(comparedTo other: EditorMarkupState) -> Bool {
        strokes != other.strokes || stickers != other.stickers
    }

    func hasBeautifyChanges(comparedTo other: EditorMarkupState) -> Bool {
        beautifyCornerRadius != other.beautifyCornerRadius
            || beautifyShadow != other.beautifyShadow
            || beautifyFrame != other.beautifyFrame
    }

    mutating func appendStroke(_ stroke: MarkupStroke) {
        strokes.append(stroke)
        history.append(.stroke)
    }

    mutating func undoLast() {
        while let last = history.popLast() {
            if last == .stroke, !strokes.isEmpty { strokes.removeLast(); return }
            if last == .sticker, !stickers.isEmpty { stickers.removeLast(); return }
        }
        if !strokes.isEmpty { strokes.removeLast() } else if !stickers.isEmpty { stickers.removeLast() }
    }

    mutating func addSticker(text: String, normalizedCenter: CGPoint) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let clamped = CGPoint(
            x: min(0.94, max(0.06, normalizedCenter.x)),
            y: min(0.94, max(0.06, normalizedCenter.y))
        )
        let sticker = TextSticker(
            text: trimmed,
            position: clamped,
            color: textColor,
            hasBackground: textHasBackground,
            fontSizeFraction: 16.0 / Self.referenceWidth
        )
        stickers.append(sticker)
        history.append(.sticker)
    }
}

/// Interactive overlay bound directly to the stitched image in normalized (`0...1`) coordinates.
struct EditorMarkupOverlay: View {
    let activeTool: EditorTool?
    var isInteractive: Bool = true
    var cancelToken: Int = 0
    @Binding var markup: EditorMarkupState

    @State private var activeStroke: MarkupStroke?

    private var isDrawingToolActive: Bool {
        isInteractive && (activeTool == .draw || (activeTool == .redact && markup.redactMode == .manual))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                strokeCanvas
                MarkupGestureCaptureView(
                    isEnabled: isDrawingToolActive,
                    onBegan: { activeStroke = makeInitialStroke(at: $0) },
                    onChanged: { activeStroke?.points.append($0) },
                    onEnded: {
                        if let finished = activeStroke, !finished.points.isEmpty {
                            markup.appendStroke(finished)
                        }
                        activeStroke = nil
                    },
                    onCancelled: { activeStroke = nil }
                )
                ForEach($markup.stickers) { $sticker in
                    DraggableStickerView(
                        sticker: $sticker,
                        canvasSize: geo.size,
                        isInteractive: isInteractive
                    ) {
                        markup.stickers.removeAll { $0.id == sticker.id }
                    }
                }
            }
            .coordinateSpace(name: "EditorMarkupOverlaySpace")
            .onChange(of: cancelToken) { _ in activeStroke = nil }
        }
    }

    private var strokeCanvas: some View {
        Canvas { context, size in
            for stroke in markup.strokes { drawStroke(stroke, size: size, in: &context) }
            if let current = activeStroke { drawStroke(current, size: size, in: &context) }
        }
        .allowsHitTesting(false)
    }

    private func makeInitialStroke(at point: CGPoint) -> MarkupStroke {
        let ref = EditorMarkupState.referenceWidth
        if activeTool == .redact {
            let color: Color = markup.manualRedactStyle == .mosaic ? Color(white: 0.78)
                : (markup.manualRedactStyle == .blur ? .white : .black)
            let opacity: Double = markup.manualRedactStyle == .mosaic ? 0.92
                : (markup.manualRedactStyle == .blur ? 0.45 : 0.96)
            return MarkupStroke(
                points: [point], color: color, lineWidthFraction: 22 / ref,
                opacity: opacity, brushStyle: .pen, redactStyle: markup.manualRedactStyle
            )
        }
        let isHighlighter = markup.brushStyle == .highlighter
        let widthPt = isHighlighter ? max(14, markup.brushWidth * 2.4) : markup.brushWidth
        return MarkupStroke(
            points: [point], color: markup.brushColor, lineWidthFraction: widthPt / ref,
            opacity: isHighlighter ? 0.38 : 1.0, brushStyle: markup.brushStyle
        )
    }
}

// MARK: - Canvas Drawing Helpers

private extension EditorMarkupOverlay {
    func denormalize(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }

    func drawStroke(_ stroke: MarkupStroke, size: CGSize, in context: inout GraphicsContext) {
        let pts = stroke.points.map { denormalize($0, in: size) }
        guard let first = pts.first else { return }
        let lineWidth = max(1.5, stroke.lineWidthFraction * max(1, size.width))
        if let redactStyle = stroke.redactStyle {
            drawRedact(pts, style: redactStyle, lineWidth: lineWidth, stroke: stroke, size: size, in: &context)
            return
        }
        switch stroke.brushStyle {
        case .pen, .highlighter: drawFreehand(pts, start: first, lineWidth: lineWidth, stroke: stroke, in: &context)
        case .arrow: drawArrow(pts, start: first, lineWidth: lineWidth, stroke: stroke, in: &context)
        case .rect: drawRect(pts, start: first, lineWidth: lineWidth, stroke: stroke, in: &context)
        }
    }

    func drawFreehand(
        _ points: [CGPoint], start: CGPoint, lineWidth: CGFloat, stroke: MarkupStroke, in context: inout GraphicsContext
    ) {
        var path = Path()
        path.move(to: start)
        if points.count == 1 { path.addLine(to: CGPoint(x: start.x + 0.5, y: start.y + 0.5)) }
        else { for point in points.dropFirst() { path.addLine(to: point) } }
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        context.stroke(path, with: .color(stroke.color.opacity(stroke.opacity)), style: style)
    }

    func drawArrow(
        _ points: [CGPoint], start: CGPoint, lineWidth: CGFloat, stroke: MarkupStroke, in context: inout GraphicsContext
    ) {
        let end = points.last ?? start
        var path = Path()
        path.move(to: start); path.addLine(to: end)
        let angle = atan2(end.y - start.y, end.x - start.x)
        let head = max(12, lineWidth * 3), spread: CGFloat = .pi / 6
        path.move(to: CGPoint(x: end.x - head * cos(angle - spread), y: end.y - head * sin(angle - spread)))
        path.addLine(to: end)
        path.addLine(to: CGPoint(x: end.x - head * cos(angle + spread), y: end.y - head * sin(angle + spread)))
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        context.stroke(path, with: .color(stroke.color.opacity(stroke.opacity)), style: style)
    }

    func drawRect(
        _ points: [CGPoint], start: CGPoint, lineWidth: CGFloat, stroke: MarkupStroke, in context: inout GraphicsContext
    ) {
        let end = points.last ?? start
        let rect = CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: max(2, abs(end.x - start.x)), height: max(2, abs(end.y - start.y))
        )
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        context.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(stroke.color.opacity(stroke.opacity)), style: style)
    }

    func drawRedact(
        _ points: [CGPoint], style: ManualRedactStyle, lineWidth: CGFloat,
        stroke: MarkupStroke, size: CGSize, in context: inout GraphicsContext
    ) {
        guard let first = points.first else { return }
        guard style == .mosaic else {
            drawFreehand(points, start: first, lineWidth: lineWidth, stroke: stroke, in: &context)
            return
        }
        let cell = max(4, size.width * 0.018)
        for point in points {
            let sx = floor(point.x / cell) * cell, sy = floor(point.y / cell) * cell
            for dx in [-cell, 0, cell] {
                for dy in [-cell, 0, cell] {
                    let gx = sx + dx, gy = sy + dy
                    let shade = ((Int(gx / cell) + Int(gy / cell)) % 2 == 0)
                        ? Color(white: 0.72, opacity: 0.9) : Color(white: 0.34, opacity: 0.9)
                    context.fill(Path(CGRect(x: gx, y: gy, width: cell, height: cell)), with: .color(shade))
                }
            }
        }
    }
}

// MARK: - Subviews

private struct DraggableStickerView: View {
    @Binding var sticker: TextSticker
    let canvasSize: CGSize
    let isInteractive: Bool
    let onDelete: () -> Void

    @State private var dragStart: CGPoint?

    var body: some View {
        let w = max(1, canvasSize.width), h = max(1, canvasSize.height)
        let fontSize = max(11, sticker.fontSizeFraction * w)
        return HStack(spacing: 6) {
            Text(sticker.text)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(sticker.color)
            if isInteractive {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: max(12, fontSize * 0.85), weight: .semibold))
                        .foregroundStyle(sticker.hasBackground ? sticker.color.opacity(0.85) : Color.primary.opacity(0.75))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("删除文字贴纸")
            }
        }
        .padding(.horizontal, sticker.hasBackground ? 12 : 6)
        .padding(.vertical, sticker.hasBackground ? 7 : 4)
        .background(stickerBackground)
        .shadow(color: Color.black.opacity(0.35), radius: 6, y: 2)
        .position(CGPoint(x: sticker.position.x * w, y: sticker.position.y * h))
        .allowsHitTesting(isInteractive)
        .highPriorityGesture(
            DragGesture(coordinateSpace: .named("EditorMarkupOverlaySpace"))
                .onChanged { value in
                    guard isInteractive else { return }
                    if dragStart == nil { dragStart = sticker.position }
                    guard let start = dragStart else { return }
                    let nx = start.x + value.translation.width / w
                    let ny = start.y + value.translation.height / h
                    sticker.position = CGPoint(x: min(0.96, max(0.04, nx)), y: min(0.96, max(0.04, ny)))
                }
                .onEnded { _ in dragStart = nil },
            including: isInteractive ? .all : .none
        )
    }

    @ViewBuilder
    private var stickerBackground: some View {
        if sticker.hasBackground {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.68))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
        }
    }
}
