// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreGraphics
import XCTest
@testable import PostShot

/// Validates two-stage decoupled stitching (`Alignment Chain` vs `Output Head/Tail Crop`)
/// so user head/tail trims never trigger re-alignment or `.unsafeSeam`.
final class DecoupledStitchCropTests: XCTestCase {

    // MARK: - Synthetic Frame Helpers

    private func makeGrayImage(width: Int, height: Int, pixels: [UInt8]) -> CGImage {
        var copy = pixels
        return copy.withUnsafeMutableBytes { ptr -> CGImage in
            let ctx = CGContext(
                data: ptr.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )!
            return ctx.makeImage()!
        }
    }

    private func grayPixels(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var out = [UInt8](repeating: 0, count: w * h)
        out.withUnsafeMutableBytes { ptr in
            let ctx = CGContext(
                data: ptr.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return out
    }

    private func rowMean(_ pixels: [UInt8], width: Int, y: Int) -> Int {
        let start = y * width
        let sum = (0..<width).reduce(0) { $0 + Int(pixels[start + $1]) }
        return sum / max(1, width)
    }

    private func makeBodyCanvas(width: Int, height: Int, seed: UInt64) -> [UInt8] {
        var px = [UInt8](repeating: 200, count: width * height)
        var state = seed &+ 0x9E3779B97F4A7C15
        for y in 0..<height {
            let rowTone = 148 + ((y * 19) % 36)
            for x in 0..<width {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let jitter = Int((state >> 58) & 0x1F)
                px[y * width + x] = UInt8(min(225, rowTone + jitter))
            }
        }
        return px
    }

    /// Builds a 160x400 frame with static top status/nav bar (15% = 60px) and bottom tab bar (12% = 48px).
    private func makeStaticChromeFrame(
        width: Int = 160, height: Int = 400, bodySource: [UInt8], scrollY: Int
    ) -> CGImage {
        let topBarH = 60   // 15% of 400 (0..<24 status, 24..<60 nav)
        let botBarH = 48   // 12% of 400 (352..<400 footer)
        let bodyEnd = height - botBarH
        var px = [UInt8](repeating: 0, count: width * height)
        for y in 0..<24 {
            for x in 0..<width { px[y * width + x] = 35 }
        }
        for y in 24..<topBarH {
            for x in 0..<width { px[y * width + x] = 105 }
        }
        for y in topBarH..<bodyEnd {
            let srcY = scrollY + (y - topBarH)
            for x in 0..<width { px[y * width + x] = bodySource[srcY * width + x] }
        }
        for y in bodyEnd..<height {
            for x in 0..<width { px[y * width + x] = 65 }
        }
        return makeGrayImage(width: width, height: height, pixels: px)
    }

    private func assertContiguousSpans(_ spans: [SegmentSpan], expectedCount: Int) {
        XCTAssertEqual(spans.count, expectedCount)
        XCTAssertEqual(spans.first?.topFraction ?? -1, 0, accuracy: 1e-4)
        XCTAssertEqual(spans.last?.bottomFraction ?? -1, 1, accuracy: 1e-4)
        for i in spans.indices {
            XCTAssertGreaterThan(spans[i].bottomFraction, spans[i].topFraction)
            if i > 0 {
                XCTAssertEqual(spans[i].topFraction, spans[i - 1].bottomFraction, accuracy: 1e-4)
            }
        }
    }

    // MARK: - Tests

    func testDecoupledRecompositeAdjustsHeadAndTailMonotonicallyWithoutRealignment() throws {
        let w = 160, h = 400
        let body = makeBodyCanvas(width: w, height: 1000, seed: 4242)
        let frames = [0, 120, 240].map { makeStaticChromeFrame(width: w, height: h, bodySource: body, scrollY: $0) }

        var opts = StitchEngine.Options()
        opts.topCropFraction = 0.15
        opts.bottomCropFraction = 0.12
        opts.headerMode = .none
        opts.keepFooter = false

        let engine = StitchEngine()
        let baseReport = try engine.stitchWithReportSync(images: frames, options: opts).get()
        let chain = try XCTUnwrap(baseReport.resolvedChain)
        XCTAssertEqual(chain.baseSegments.count, 3)

        let fullHead = try engine.recompositeSync(
            chain: chain, outputTopFraction: 0.0, outputBottomFraction: 0.0, removeScrollIndicator: true
        ).get()
        let navOnly = try engine.recompositeSync(
            chain: chain, outputTopFraction: 0.06, outputBottomFraction: 0.0, removeScrollIndicator: true
        ).get()
        let deepTrim = try engine.recompositeSync(
            chain: chain, outputTopFraction: 0.22, outputBottomFraction: 0.20, removeScrollIndicator: true
        ).get()

        XCTAssertGreaterThan(fullHead.image.height, navOnly.image.height)
        XCTAssertGreaterThan(navOnly.image.height, deepTrim.image.height)

        assertContiguousSpans(fullHead.segmentSpans, expectedCount: 3)
        assertContiguousSpans(navOnly.segmentSpans, expectedCount: 3)
        assertContiguousSpans(deepTrim.segmentSpans, expectedCount: 3)

        let fullPx = grayPixels(fullHead.image)
        XCTAssertEqual(rowMean(fullPx, width: w, y: 10), 35, accuracy: 2, "Status bar preserved at top=0.0")
        XCTAssertEqual(rowMean(fullPx, width: w, y: 40), 105, accuracy: 2, "Nav bar preserved at top=0.0")
        XCTAssertEqual(rowMean(fullPx, width: w, y: fullHead.image.height - 12), 65, accuracy: 2, "Footer preserved at bottom=0.0")

        let navPx = grayPixels(navOnly.image)
        XCTAssertEqual(rowMean(navPx, width: w, y: 10), 105, accuracy: 2, "Nav bar visible at top=0.06")

        let deepPx = grayPixels(deepTrim.image)
        XCTAssertGreaterThan(rowMean(deepPx, width: w, y: 2), 140, "Deep top trim removes bars cleanly")
        XCTAssertGreaterThan(rowMean(deepPx, width: w, y: deepTrim.image.height - 3), 140, "Deep bottom trim removes footer cleanly")
    }

    func testExtremeOutputCropIsClampedSafelyWithoutInvertingSeams() throws {
        let w = 160, h = 400
        let body = makeBodyCanvas(width: w, height: 1000, seed: 7788)
        let frames = [0, 120, 240].map { makeStaticChromeFrame(width: w, height: h, bodySource: body, scrollY: $0) }

        var opts = StitchEngine.Options()
        opts.topCropFraction = 0.15
        opts.bottomCropFraction = 0.12

        let engine = StitchEngine()
        let baseReport = try engine.stitchWithReportSync(images: frames, options: opts).get()
        let chain = try XCTUnwrap(baseReport.resolvedChain)

        let extreme = try engine.recompositeSync(
            chain: chain, outputTopFraction: 0.45, outputBottomFraction: 0.45, removeScrollIndicator: true
        ).get()
        XCTAssertGreaterThan(extreme.image.height, 0)
        assertContiguousSpans(extreme.segmentSpans, expectedCount: 3)

        let (croppedSegs, topRows, bottomRows) = chain.segmentsWithOutputCrop(topFraction: 0.45, bottomFraction: 0.45)
        XCTAssertEqual(topRows, 0)
        XCTAssertEqual(bottomRows, 0)
        XCTAssertGreaterThanOrEqual(croppedSegs[0].image.height, croppedSegs[1].overlap + 4)
        XCTAssertGreaterThanOrEqual(croppedSegs[2].image.height, croppedSegs[2].overlap + 4)
    }

    func testSingleSegmentAndAsyncRecompositeWorkCleanly() throws {
        let w = 160, h = 400
        let body = makeBodyCanvas(width: w, height: 500, seed: 9911)
        let single = makeStaticChromeFrame(width: w, height: h, bodySource: body, scrollY: 0)

        var opts = StitchEngine.Options()
        opts.topCropFraction = 0.15
        opts.bottomCropFraction = 0.12

        let engine = StitchEngine()
        let baseReport = try engine.stitchWithReportSync(images: [single], options: opts).get()
        let chain = try XCTUnwrap(baseReport.resolvedChain)

        let exp = expectation(description: "async recomposite")
        var asyncResult: Result<StitchReport, StitchEngine.StitchError>?
        engine.recomposite(
            chain: chain, outputTopFraction: 0.45, outputBottomFraction: 0.45, removeScrollIndicator: false
        ) { result in
            asyncResult = result
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)

        let report = try XCTUnwrap(asyncResult).get()
        XCTAssertEqual(report.image.height, 40)
        assertContiguousSpans(report.segmentSpans, expectedCount: 1)
    }
}
