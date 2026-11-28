// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
import CoreGraphics
import SwiftUI
@testable import PostShot

/// Validates `SegmentSpan` geometry, `StitchEngine` span reporting, and normalized markup state.
final class EditorMarkupAndSpanTests: XCTestCase {

    // MARK: - Synthetic Builders

    private func makePatternImage(width: Int, height: Int, seed: UInt64) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        var state = seed &+ 0x9E3779B97F4A7C15
        func next() -> UInt8 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8((state >> 33) & 0xFF)
        }
        for y in 0..<height {
            let base = UInt8((y &* 37) & 0xFF)
            for x in 0..<width {
                pixels[y * width + x] = base &+ (next() & 0x3F)
            }
        }
        let cs = CGColorSpaceCreateDeviceGray()
        return pixels.withUnsafeMutableBytes { ptr -> CGImage in
            let ctx = CGContext(
                data: ptr.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue
            )!
            return ctx.makeImage()!
        }
    }

    private func crop(_ source: CGImage, startRow: Int, height: Int) -> CGImage {
        source.cropping(to: CGRect(x: 0, y: startRow, width: source.width, height: height))!
    }

    // MARK: - SegmentSpan Computation

    func testSingleSegmentSpanCoversFullCanvas() throws {
        let img = makePatternImage(width: 120, height: 300, seed: 1)
        let spans = try ImageCompositor.computeSegmentSpans(
            segments: [.init(image: img, overlap: 0, sourceIndex: 0)],
            width: 120
        )
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].sourceIndex, 0)
        XCTAssertEqual(spans[0].topFraction, 0, accuracy: 1e-6)
        XCTAssertEqual(spans[0].bottomFraction, 1, accuracy: 1e-6)
    }

    func testTwoEqualSegmentsWithOverlapSplitAtMidpoint() throws {
        let a = makePatternImage(width: 100, height: 100, seed: 2)
        let b = makePatternImage(width: 100, height: 100, seed: 3)
        let spans = try ImageCompositor.computeSegmentSpans(
            segments: [
                .init(image: a, overlap: 0, sourceIndex: 0),
                .init(image: b, overlap: 20, sourceIndex: 1)
            ],
            width: 100
        )
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].topFraction, 0, accuracy: 1e-6)
        XCTAssertEqual(spans[0].bottomFraction, 0.5, accuracy: 1e-6)
        XCTAssertEqual(spans[1].topFraction, 0.5, accuracy: 1e-6)
        XCTAssertEqual(spans[1].bottomFraction, 1.0, accuracy: 1e-6)
    }

    func testThreeSegmentsWithVariedOverlapsAreContiguousAndMonotonic() throws {
        let a = makePatternImage(width: 100, height: 200, seed: 4)
        let b = makePatternImage(width: 100, height: 200, seed: 5)
        let c = makePatternImage(width: 100, height: 200, seed: 6)
        let spans = try ImageCompositor.computeSegmentSpans(
            segments: [
                .init(image: a, overlap: 0, sourceIndex: 0),
                .init(image: b, overlap: 40, sourceIndex: 1),
                .init(image: c, overlap: 60, sourceIndex: 2)
            ],
            width: 100
        )
        // Total height = 200 + 160 + 140 = 500; seams at 160 + 20 = 180 and 300 + 30 = 330
        XCTAssertEqual(spans.count, 3)
        XCTAssertEqual(spans[0].topFraction, 0, accuracy: 1e-6)
        XCTAssertEqual(spans[0].bottomFraction, 180.0 / 500.0, accuracy: 1e-6)
        XCTAssertEqual(spans[1].topFraction, spans[0].bottomFraction, accuracy: 1e-6)
        XCTAssertEqual(spans[1].bottomFraction, 330.0 / 500.0, accuracy: 1e-6)
        XCTAssertEqual(spans[2].topFraction, spans[1].bottomFraction, accuracy: 1e-6)
        XCTAssertEqual(spans[2].bottomFraction, 1.0, accuracy: 1e-6)
    }

    func testStitchReportSpansTrackSkippedOutlierSourceIndex() throws {
        let canvas = makePatternImage(width: 160, height: 800, seed: 42)
        let frame0 = crop(canvas, startRow: 0, height: 340)
        let outlier = makePatternImage(width: 160, height: 340, seed: 999)
        let frame2 = crop(canvas, startRow: 220, height: 340)

        let engine = StitchEngine()
        var options = StitchEngine.Options()
        options.removeScrollIndicator = false
        let report = try engine.stitchWithReportSync(images: [frame0, outlier, frame2], options: options).get()

        XCTAssertEqual(report.skippedIndices, [1])
        XCTAssertEqual(report.segmentSpans.map(\.sourceIndex), [0, 2])
        XCTAssertEqual(report.segmentSpans.first?.topFraction ?? -1, 0, accuracy: 1e-6)
        XCTAssertEqual(report.segmentSpans.last?.bottomFraction ?? -1, 1, accuracy: 1e-6)
    }

    // MARK: - Normalized Markup & Tools

    func testEditorToolExcludesDesktopMoveTool() {
        XCTAssertEqual(EditorTool.allCases, [.redact, .text, .draw])
        XCTAssertEqual(EditorPrimaryTab.allCases, [.crop, .markup, .beautify])
    }

    func testMarkupAndBeautifyDirtyTrackingReflectsEditsAndUndo() {
        let baseline = EditorMarkupState()
        var state = baseline
        XCTAssertFalse(state.hasMarkupChanges(comparedTo: baseline))
        XCTAssertFalse(state.hasBeautifyChanges(comparedTo: baseline))

        state.appendStroke(MarkupStroke(
            points: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.2)],
            color: .red,
            lineWidthFraction: 5 / 360,
            opacity: 1
        ))
        XCTAssertTrue(state.hasMarkupChanges(comparedTo: baseline))

        state.undoLast()
        XCTAssertFalse(state.hasMarkupChanges(comparedTo: baseline))

        state.beautifyShadow.toggle()
        XCTAssertTrue(state.hasBeautifyChanges(comparedTo: baseline))
        state.beautifyShadow = baseline.beautifyShadow
        XCTAssertFalse(state.hasBeautifyChanges(comparedTo: baseline))
    }

    func testMarkupStateClampsNormalizedStickerAndUndoesInOrder() {
        var state = EditorMarkupState()
        state.addSticker(text: "  重点标注  ", normalizedCenter: CGPoint(x: 1.5, y: -0.4))
        XCTAssertEqual(state.stickers.count, 1)
        XCTAssertEqual(state.stickers[0].text, "重点标注")
        XCTAssertEqual(state.stickers[0].position.x, 0.94, accuracy: 1e-6)
        XCTAssertEqual(state.stickers[0].position.y, 0.06, accuracy: 1e-6)

        state.appendStroke(MarkupStroke(
            points: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.8, y: 0.2)],
            color: .red,
            lineWidthFraction: 5 / 360,
            opacity: 1
        ))
        XCTAssertTrue(state.hasActiveAnnotations)

        state.undoLast()
        XCTAssertTrue(state.strokes.isEmpty)
        XCTAssertEqual(state.stickers.count, 1)

        state.undoLast()
        XCTAssertFalse(state.hasActiveAnnotations)
    }

    // MARK: - Canvas Corner Scaling & Shape Geometry

    func testScaledCornerRadiusScalesProportionallyAndClamps() {
        XCTAssertEqual(EditorMarkupState.scaledCornerRadius(0, for: CGSize(width: 360, height: 800)), 0)
        XCTAssertEqual(EditorMarkupState.scaledCornerRadius(-4, for: CGSize(width: 360, height: 800)), 0)
        XCTAssertEqual(EditorMarkupState.scaledCornerRadius(20, for: CGSize(width: 0, height: 800)), 0)
        XCTAssertEqual(EditorMarkupState.scaledCornerRadius(20, for: CGSize(width: 360, height: 0)), 0)

        XCTAssertEqual(EditorMarkupState.scaledCornerRadius(20, for: CGSize(width: 360, height: 800)), 20, accuracy: 1e-6)
        XCTAssertEqual(EditorMarkupState.scaledCornerRadius(20, for: CGSize(width: 180, height: 400)), 10, accuracy: 1e-6)
        XCTAssertEqual(EditorMarkupState.scaledCornerRadius(20, for: CGSize(width: 1080, height: 2400)), 60, accuracy: 1e-6)

        // Clamped to 45% of shorter edge on very short or small canvases.
        XCTAssertEqual(EditorMarkupState.scaledCornerRadius(20, for: CGSize(width: 360, height: 24)), 24 * 0.45, accuracy: 1e-6)
    }

    func testScaledCanvasRoundedRectMatchesSharpAndSelectiveCorners() {
        let rect = CGRect(x: 0, y: 0, width: 360, height: 200)
        let sharpPath = ScaledCanvasRoundedRect(baseCornerRadius: 0).path(in: rect)
        XCTAssertTrue(sharpPath.contains(CGPoint(x: 1, y: 1)))
        XCTAssertTrue(sharpPath.contains(CGPoint(x: 1, y: rect.height - 1)))

        let noCornersPath = ScaledCanvasRoundedRect(
            baseCornerRadius: 20,
            topCorners: false,
            bottomCorners: false
        ).path(in: rect)
        XCTAssertTrue(noCornersPath.contains(CGPoint(x: 1, y: 1)))
        XCTAssertTrue(noCornersPath.contains(CGPoint(x: 1, y: rect.height - 1)))

        let topOnlyPath = ScaledCanvasRoundedRect(
            baseCornerRadius: 20,
            topCorners: true,
            bottomCorners: false,
            referenceCanvasSize: CGSize(width: 360, height: 600)
        ).path(in: rect)
        XCTAssertFalse(topOnlyPath.contains(CGPoint(x: 1, y: 1)))
        XCTAssertTrue(topOnlyPath.contains(CGPoint(x: 1, y: rect.height - 1)))

        let bottomOnlyPath = ScaledCanvasRoundedRect(
            baseCornerRadius: 20,
            topCorners: false,
            bottomCorners: true,
            referenceCanvasSize: CGSize(width: 360, height: 600)
        ).path(in: rect)
        XCTAssertTrue(bottomOnlyPath.contains(CGPoint(x: 1, y: 1)))
        XCTAssertFalse(bottomOnlyPath.contains(CGPoint(x: 1, y: rect.height - 1)))

        let insetShape = ScaledCanvasRoundedRect(baseCornerRadius: 20).inset(by: 1)
        let insetPath = insetShape.path(in: rect)
        XCTAssertFalse(insetPath.contains(CGPoint(x: 2, y: 2)))
        XCTAssertTrue(insetPath.contains(CGPoint(x: 180, y: 100)))
    }
}
