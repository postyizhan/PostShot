// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PostShot

/// Covers universal seam cleanup, frosted-glass bar detection with Control Center outliers,
/// tall-frame multi-peak alignment, outlier skipping, and disk-pool gap backfill.
final class BackfillAndUniversalStitchTests: XCTestCase {

    // MARK: - Helpers

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

    private func makeScrollSource(width: Int, height: Int, seed: UInt64) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        var state = seed &+ 0x9E3779B97F4A7C15
        for y in 0..<height {
            let rowBase = UInt8((y &* 41) & 0xFF)
            for x in 0..<width {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                pixels[y * width + x] = rowBase &+ UInt8((state >> 33) & 0x3F)
            }
        }
        return makeGrayImage(width: width, height: height, pixels: pixels)
    }

    private func crop(_ image: CGImage, startRow: Int, height: Int) -> CGImage {
        image.cropping(to: CGRect(x: 0, y: startRow, width: image.width, height: height))!
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

    private func encodePNG(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    // MARK: - 1. Midpoint Seam Eliminates Residual Separator Lines

    func testMidpointSeamEliminatesResidualTopAndBottomHairlines() throws {
        let w = 64, windowH = 300, overlap = 120
        // Clean flat-gray canvas (237 = #EDEDED) where every cropped frame still carries a 2px
        // semi-transparent nav hairline (190) at its top edge and input shadow (200) at its bottom.
        let makeFrameWithEdgeHairlines = { () -> CGImage in
            var px = [UInt8](repeating: 237, count: w * windowH)
            for y in 0..<2 {
                for x in 0..<w { px[y * w + x] = 190 }
            }
            for y in (windowH - 2)..<windowH {
                for x in 0..<w { px[y * w + x] = 200 }
            }
            return self.makeGrayImage(width: w, height: windowH, pixels: px)
        }
        let segments = [
            ImageCompositor.Segment(image: makeFrameWithEdgeHairlines(), overlap: 0),
            ImageCompositor.Segment(image: makeFrameWithEdgeHairlines(), overlap: overlap),
            ImageCompositor.Segment(image: makeFrameWithEdgeHairlines(), overlap: overlap),
        ]
        let out = try ImageCompositor.composite(segments: segments, width: w)
        let px = grayPixels(out)
        for y in 4..<(out.height - 4) {
            let rowAvg = (0..<w).reduce(0) { $0 + Int(px[y * w + $1]) } / w
            XCTAssertEqual(rowAvg, 237, accuracy: 2, "Interior row \(y) must have no residual seam line")
        }
    }

    // MARK: - 2. Frosted-Glass Bars + Control Center Outlier Filtering

    func testFrostedGlassBarsDetectedDespiteBlurredTintAndControlCenterOutliers() {
        let w = 320, h = 700
        let topBar = 84    // 12.0%
        let bottomBar = 63 // 9.0%
        // 4 Safari-like frames with frosted-glass bars whose background brightness drifts by ~0.05
        // across frames while icons and 1px separators remain fixed.
        let tints: [UInt8] = [218, 226, 231, 222]
        var frames: [CGImage] = tints.enumerated().map { idx, tint in
            var px = [UInt8](repeating: 248, count: w * h)
            for y in 0..<topBar {
                for x in 0..<w { px[y * w + x] = tint }
            }
            // Static address-bar glyphs & hairline separator on top of frosted glass.
            for y in 46..<62 {
                for x in 40..<70 { px[y * w + x] = 55 }
                for x in 130..<205 { px[y * w + x] = 60 }
            }
            for x in 0..<w { px[(topBar - 1) * w + x] = 175 }

            for y in (h - bottomBar)..<h {
                for x in 0..<w { px[y * w + x] = tint }
            }
            for x in 0..<w { px[(h - bottomBar) * w + x] = 175 }
            for y in (h - 42)..<(h - 26) {
                for x in [60, 160, 260] {
                    for dx in 0..<16 { px[y * w + x + dx] = 50 }
                }
            }
            // Sharp scrolling article lines in body.
            let scroll = idx * 130
            for y in topBar..<(h - bottomBar) where (y + scroll) % 28 < 5 {
                for x in 24..<(w - 28) where (x + y + scroll) % 4 != 0 {
                    px[y * w + x] = 35
                }
            }
            return makeGrayImage(width: w, height: h, pixels: px)
        }
        // Append 2 dark Control Center outlier frames at the end (user stopping recording).
        let ccPixels = (0..<(w * h)).map { idx -> UInt8 in UInt8(45 + ((idx / w) % 23)) }
        frames.append(makeGrayImage(width: w, height: h, pixels: ccPixels))
        frames.append(makeGrayImage(width: w, height: h, pixels: ccPixels))

        let (top, bottom) = FixedBarDetector.detectFractions(frames)
        XCTAssertEqual(top, Float(topBar) / Float(h) + 0.005, accuracy: 0.015,
                       "Frosted top bar must be detected even with 2 Control Center tail frames")
        XCTAssertEqual(bottom, Float(bottomBar) / Float(h) + 0.005, accuracy: 0.015,
                       "Frosted bottom bar must be detected even with 2 Control Center tail frames")
    }

    // MARK: - 3. Tall Screenshot Moderate Overlap Stability

    func testTallSparseDocumentModerateOverlapMatchesAccurately() {
        let w = 128, tallH = 2200, winH = 900, knownOverlap = 220
        var px = [UInt8](repeating: 245, count: w * tallH)
        var rng: UInt64 = 0xABCDEF0123456789
        for y in 0..<tallH {
            if y % 47 < 7 {
                rng = rng &* 6364136223846793005 &+ 1442695040888963407
                let rightEnd = 50 + Int((rng >> 40) % 65)
                for x in 18..<rightEnd where (x + y * 3) % 5 != 0 {
                    px[y * w + x] = 40
                }
            }
        }
        let source = makeGrayImage(width: w, height: tallH, pixels: px)
        let top = crop(source, startRow: 0, height: winH)
        let bottom = crop(source, startRow: winH - knownOverlap, height: winH)

        let result = OverlapDetector.detect(top: top, bottom: bottom)
        XCTAssertEqual(result.status, .matched)
        XCTAssertEqual(result.overlap, knownOverlap, accuracy: 2)
    }

    // MARK: - 4. Automatic Skipping of Leading, Middle, and Trailing Outliers

    func testEngineSkipsControlCenterOutliersAtStartMiddleAndEnd() {
        let w = 64, winH = 360
        let source = makeScrollSource(width: w, height: 1200, seed: 303)
        let p0 = crop(source, startRow: 0, height: winH)
        let p1 = crop(source, startRow: 200, height: winH)   // 160 overlap with p0
        let p2 = crop(source, startRow: 400, height: winH)   // 160 overlap with p1
        let ccA = makeScrollSource(width: w, height: winH, seed: 9001)
        let ccB = makeScrollSource(width: w, height: winH, seed: 9002)
        let ccC = makeScrollSource(width: w, height: winH, seed: 9003)

        let inputs = [ccA, p0, ccB, p1, p2, ccC]
        switch StitchEngine().stitchWithReportSync(images: inputs) {
        case .success(let report):
            XCTAssertEqual(report.skippedIndices, [0, 2, 5])
            XCTAssertEqual(report.image.height, 760, accuracy: 4, "360 + 200 + 200")
        case .failure(let error):
            XCTFail("Expected automatic outlier skip to succeed, got \(error)")
        }
    }

    // MARK: - 5. Disk Pool Gap Backfill + Pre-Outlier Tail Rescue

    func testEngineBackfillsFastScrollGapAndRescuesTailFromDiskStore() {
        let w = 64, winH = 360
        let source = makeScrollSource(width: w, height: 1800, seed: 515)
        let store = CaptureFrameStore()
        defer { store.reset() }

        // Pool indices 0...6 advance by 150px each (210px overlap between adjacent pool frames).
        // Primary selection skipped 1..3 -> p0 (start=0) vs p4 (start=600) has ZERO direct overlap!
        // Pool index 6 (start=900) is the true bottom of the page; pool index 7 is Control Center!
        var poolImages: [CGImage] = (0...6).map { crop(source, startRow: $0 * 150, height: winH) }
        poolImages.append(makeScrollSource(width: w, height: winH, seed: 8888))
        for img in poolImages {
            XCTAssertNotNil(store.append(encodePNG(img)))
        }

        let sparseIndices = [0, 4, 7]
        let sparseImages = sparseIndices.compactMap { store.loadCGImage(at: $0) }
        XCTAssertEqual(sparseImages.count, 3)

        var options = StitchEngine.Options()
        options.backfill = FrameBackfillSource(
            poolIndices: sparseIndices,
            loadFrame: { store.loadCGImage(at: $0) }
        )

        switch StitchEngine().stitchWithReportSync(images: sparseImages, options: options) {
        case .success(let report):
            XCTAssertEqual(report.skippedIndices, [2], "Trailing Control Center frame must be skipped")
            XCTAssertGreaterThanOrEqual(report.backfilledCount, 2,
                                        "Must backfill gap 0..4 and rescue tail frame 6 before Control Center")
            // Expected full stitched span from startRow=0 through startRow=900 + 360 = 1260px!
            XCTAssertEqual(report.image.height, 1260, accuracy: 6,
                           "Backfill + tail rescue must recover the complete 0..<1260 page")
        case .failure(let error):
            XCTFail("Expected disk-pool backfill and tail rescue to succeed, got \(error)")
        }
    }
}
