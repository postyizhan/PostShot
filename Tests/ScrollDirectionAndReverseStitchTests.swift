// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PostShot

/// Deterministic tests for bidirectional scroll detection, minor backtrack skipping,
/// heavy zig-zag rejection, manual scrambled reordering, and reverse backfill.
final class ScrollDirectionAndReverseStitchTests: XCTestCase {

    private func makeSRGBImage(width: Int, height: Int, luma: [UInt8]) -> CGImage {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            let v = luma[i]
            let base = i * 4
            rgba[base] = v
            rgba[base + 1] = v
            rgba[base + 2] = v
        }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        return rgba.withUnsafeMutableBytes { ptr -> CGImage in
            let ctx = CGContext(
                data: ptr.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            return ctx.makeImage()!
        }
    }

    private func makeScrollSource(width: Int, height: Int, seed: UInt64) -> CGImage {
        var luma = [UInt8](repeating: 0, count: width * height)
        var state = seed &+ 0x9E3779B97F4A7C15
        for y in 0..<height {
            let rowBase = UInt8((y &* 41) & 0xFF)
            for x in 0..<width {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                luma[y * width + x] = rowBase &+ UInt8((state >> 33) & 0x3F)
            }
        }
        return makeSRGBImage(width: width, height: height, luma: luma)
    }

    private func crop(_ image: CGImage, startRow: Int, height: Int) -> CGImage {
        image.cropping(to: CGRect(x: 0, y: startRow, width: image.width, height: height))!
    }

    private func makeFrames(from source: CGImage, starts: [Int], windowHeight: Int) -> [CGImage] {
        starts.map { crop(source, startRow: $0, height: windowHeight) }
    }

    private func rgbaPixels(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        out.withUnsafeMutableBytes { ptr in
            let ctx = CGContext(
                data: ptr.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return out
    }

    private func encodePNG(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    private func expectSuccess(
        _ images: [CGImage], options: StitchEngine.Options = .init(),
        file: StaticString = #filePath, line: UInt = #line
    ) -> StitchReport? {
        switch StitchEngine().stitchWithReportSync(images: images, options: options) {
        case .success(let report):
            return report
        case .failure(let error):
            XCTFail("Expected stitch to succeed, got \(error)", file: file, line: line)
            return nil
        }
    }

    private func expectReverseConflict(
        _ images: [CGImage], options: StitchEngine.Options = .init(),
        file: StaticString = #filePath, line: UInt = #line
    ) {
        switch StitchEngine().stitchWithReportSync(images: images, options: options) {
        case .success(let report):
            XCTFail("Expected unsafeSeam failure, got success (height=\(report.image.height))", file: file, line: line)
        case .failure(.unsafeSeam(let seam)):
            XCTAssertTrue(seam.isReverseConflict, "Expected seam.isReverseConflict == true", file: file, line: line)
        case .failure(let other):
            XCTFail("Expected unsafeSeam, got \(other)", file: file, line: line)
        }
    }

    // MARK: - 1. Bottom-to-Top Auto-Reverse

    func testBottomToTopSequenceAutoReversesAndMatchesTopToBottomOutput() {
        let w = 64, winH = 360
        let source = makeScrollSource(width: w, height: 1100, seed: 101)
        let fwdFrames = makeFrames(from: source, starts: [0, 200, 400, 600], windowHeight: winH)
        let revFrames = Array(fwdFrames.reversed())

        guard let fwdReport = expectSuccess(fwdFrames),
              let revReport = expectSuccess(revFrames) else { return }

        XCTAssertEqual(revReport.orderAdjustment, .reversed)
        XCTAssertEqual(revReport.resolvedOrder, [3, 2, 1, 0])
        XCTAssertEqual(revReport.image.height, fwdReport.image.height)
        XCTAssertEqual(revReport.image.height, 960)
        XCTAssertEqual(rgbaPixels(revReport.image), rgbaPixels(fwdReport.image))

        let truth = crop(source, startRow: 0, height: revReport.image.height)
        XCTAssertEqual(rgbaPixels(revReport.image), rgbaPixels(truth))
    }

    // MARK: - 2. Bottom-to-Top Recording Pool Backfill + Pre-CC Top Rescue

    func testBottomToTopRecordingBackfillsFastScrollGapAndRescuesTopBeforeControlCenter() {
        let w = 64, winH = 360
        let source = makeScrollSource(width: w, height: 1800, seed: 515)
        let store = CaptureFrameStore()
        defer { store.reset() }

        // pool[0] = bottom (row 900) ... pool[6] = true top (row 0), pool[7] = Control Center.
        var poolImages = (0...6).map { crop(source, startRow: (6 - $0) * 150, height: winH) }
        poolImages.append(makeScrollSource(width: w, height: winH, seed: 8888))
        for img in poolImages { XCTAssertNotNil(store.append(encodePNG(img))) }

        let sparseIndices = [0, 4, 7]
        let sparseImages = sparseIndices.compactMap { store.loadCGImage(at: $0) }
        var options = StitchEngine.Options()
        options.backfill = FrameBackfillSource(poolIndices: sparseIndices, loadFrame: { store.loadCGImage(at: $0) })

        guard let report = expectSuccess(sparseImages, options: options) else { return }
        XCTAssertEqual(report.orderAdjustment, .reversed)
        XCTAssertEqual(report.skippedIndices, [0])
        XCTAssertGreaterThanOrEqual(report.backfilledCount, 2)
        XCTAssertEqual(report.image.height, 1260, accuracy: 6)

        // Re-stitching already-reversed frames with descending pool indices keeps .topToBottom.
        let reversedImages = Array(sparseImages.reversed())
        options.backfill = FrameBackfillSource(poolIndices: [7, 4, 0], loadFrame: { store.loadCGImage(at: $0) })
        guard let rerun = expectSuccess(reversedImages, options: options) else { return }
        XCTAssertEqual(rerun.orderAdjustment, .none)
        XCTAssertEqual(rerun.image.height, 1260, accuracy: 6)
    }

    // MARK: - 3. Minor Mid-Scroll Backtrack Skipped (Forward)

    func testMinorMidScrollBacktrackIsSkippedSeamlessly() {
        let source = makeScrollSource(width: 64, height: 1200, seed: 303)
        let frames = makeFrames(from: source, starts: [0, 200, 400, 300, 550, 750], windowHeight: 360)

        guard let report = expectSuccess(frames) else { return }
        XCTAssertEqual(report.orderAdjustment, .none)
        XCTAssertEqual(report.backtrackSkippedCount, 1)
        XCTAssertEqual(report.skippedIndices, [3])
        XCTAssertEqual(report.image.height, 1110, accuracy: 6)
    }

    // MARK: - 4. Minor Backtrack Skipped (Bottom-to-Top)

    func testMinorBacktrackDuringBottomToTopScrollIsSkippedSeamlessly() {
        let source = makeScrollSource(width: 64, height: 1200, seed: 404)
        let frames = makeFrames(from: source, starts: [750, 550, 300, 400, 200, 0], windowHeight: 360)

        guard let report = expectSuccess(frames) else { return }
        XCTAssertEqual(report.orderAdjustment, .reversed)
        XCTAssertEqual(report.backtrackSkippedCount, 1)
        XCTAssertEqual(report.skippedIndices, [3])
        XCTAssertEqual(report.image.height, 1110, accuracy: 6)
    }

    // MARK: - 5. Heavy Zig-Zag Rejected

    func testHeavyZigZagScrollIsRejectedWithReverseConflict() {
        let source = makeScrollSource(width: 64, height: 1100, seed: 505)
        let frames = makeFrames(from: source, starts: [0, 200, 400, 600, 400, 200, 0], windowHeight: 360)
        var options = StitchEngine.Options()
        options.allowAutoReorder = false

        expectReverseConflict(frames, options: options)
    }

    // MARK: - 6. Repeated Oscillations Beyond Limit Rejected

    func testRepeatedOscillationsBeyondLimitAreRejected() {
        let source = makeScrollSource(width: 64, height: 1100, seed: 606)
        let frames = makeFrames(from: source, starts: [0, 200, 120, 350, 260, 500, 410, 650], windowHeight: 360)
        var options = StitchEngine.Options()
        options.allowAutoReorder = false

        expectReverseConflict(frames, options: options)
    }

    // MARK: - 7. Manual Mode Auto-Reorders Scrambled Screenshots

    func testManualModeAutoReordersScrambledScreenshots() {
        let source = makeScrollSource(width: 64, height: 1100, seed: 707)
        let ordered = makeFrames(from: source, starts: [0, 200, 400, 600], windowHeight: 360)
        let scrambled = [ordered[2], ordered[0], ordered[3], ordered[1]]

        var options = StitchEngine.Options()
        options.allowAutoReorder = true

        guard let report = expectSuccess(scrambled, options: options) else { return }
        XCTAssertEqual(report.orderAdjustment, .reordered)
        XCTAssertEqual(report.resolvedOrder, [1, 3, 0, 2])
        XCTAssertEqual(report.image.height, 960)
    }

    // MARK: - 8. Two-Image Reverse Sequence Auto-Reverses

    func testTwoImageReverseSequenceAutoReverses() {
        let source = makeScrollSource(width: 64, height: 700, seed: 808)
        let top = crop(source, startRow: 0, height: 360)
        let bottom = crop(source, startRow: 200, height: 360)

        guard let report = expectSuccess([bottom, top]) else { return }
        XCTAssertEqual(report.orderAdjustment, .reversed)
        XCTAssertEqual(report.resolvedOrder, [1, 0])
        XCTAssertEqual(report.segmentSpans.map(\.sourceIndex), [0, 1])
        XCTAssertEqual(report.image.height, 560)
    }

    // MARK: - 9. Multi-Step Small Backtrack Uses True Reverse Overlap

    func testMultiStepSmallBacktrackIsSkippedSeamlessly() {
        let source = makeScrollSource(width: 64, height: 1200, seed: 909)
        let frames = makeFrames(from: source, starts: [0, 200, 400, 350, 300, 550, 750], windowHeight: 360)

        guard let report = expectSuccess(frames) else { return }
        XCTAssertEqual(report.orderAdjustment, .none)
        XCTAssertEqual(report.backtrackSkippedCount, 2)
        XCTAssertEqual(report.skippedIndices, [3, 4])
        XCTAssertEqual(report.image.height, 1110, accuracy: 6)
    }

    // MARK: - 10. Reversed Sequence Failure Remaps Seam Indices to Input Order

    func testReversedSequenceFailureRemapsSeamIndicesToOriginalOrder() {
        let source = makeScrollSource(width: 64, height: 1200, seed: 1010)
        let f0 = crop(source, startRow: 0, height: 360)
        let f1 = crop(source, startRow: 200, height: 360)
        let outlier = makeScrollSource(width: 64, height: 360, seed: 99999)
        let f3 = crop(source, startRow: 550, height: 360)
        let f4 = crop(source, startRow: 750, height: 360)
        // Input in reverse order: [f4(0), f3(1), outlier(2), f1(3), f0(4)]
        var options = StitchEngine.Options()
        options.maxSkippedOutliers = 0
        options.allowAutoReorder = false

        switch StitchEngine().stitchWithReportSync(images: [f4, f3, outlier, f1, f0], options: options) {
        case .success:
            XCTFail("Expected unsafeSeam with maxSkippedOutliers=0")
        case .failure(.unsafeSeam(let seam)):
            XCTAssertEqual(seam.topIndex, 2)
            XCTAssertEqual(seam.bottomIndex, 3)
        case .failure(let other):
            XCTFail("Expected unsafeSeam, got \(other)")
        }
    }
}
