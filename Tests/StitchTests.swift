// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
import CoreGraphics
@testable import PostShot

/// Validates `OverlapDetector` and `StitchEngine` against synthetic images with known overlaps.
final class StitchTests: XCTestCase {

    // MARK: - Synthetic image builder

    /// Builds a tall test image whose rows are filled with a deterministic pseudo-random
    /// grayscale pattern. Rows are content-rich enough that NCC has a sharp maximum.
    private func makeImage(width: Int, height: Int, seed: UInt64) -> CGImage {
        let bytesPerRow = width
        var pixels = [UInt8](repeating: 0, count: width * height)
        var state = seed &+ 0x9E3779B97F4A7C15
        func next() -> UInt8 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8((state >> 33) & 0xFF)
        }
        // Each row gets a distinct base value so vertical position is identifiable.
        for y in 0..<height {
            let rowBase = UInt8((y &* 37) & 0xFF)
            for x in 0..<width {
                pixels[y * bytesPerRow + x] = rowBase &+ (next() & 0x3F)
            }
        }
        let cs = CGColorSpaceCreateDeviceGray()
        return pixels.withUnsafeMutableBytes { ptr -> CGImage in
            let ctx = CGContext(
                data: ptr.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue
            )!
            return ctx.makeImage()!
        }
    }

    /// Returns the sub-image of `source` spanning rows [startRow, startRow+height).
    private func crop(_ source: CGImage, startRow: Int, height: Int) -> CGImage {
        source.cropping(to: CGRect(x: 0, y: startRow, width: source.width, height: height))!
    }

    /// Reads `image` back as row-major top-down grayscale bytes (length == width*height).
    private func grayPixels(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h)
        let cs = CGColorSpaceCreateDeviceGray()
        pixels.withUnsafeMutableBytes { ptr in
            let ctx = CGContext(
                data: ptr.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w,
                space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue
            )!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return pixels
    }

    /// Builds a SMOOTH-gradient image (low spatial frequency), like real photos/screenshots where
    /// content changes gently between adjacent rows. Here NCC at overlap h and h±1 is nearly
    /// identical, so an ambiguity margin that compares the winner against its own adjacent shoulder
    /// wrongly rejects a perfect match. The detector must compare against a DISTINCT hypothesis.
    private func makeSmoothImage(width: Int, height: Int) -> CGImage {
        let bytesPerRow = width
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                // Gentle 2D gradient + a slow sine — smooth, non-periodic within a window.
                let v = 0.5 + 0.25 * sin(Double(y) * 0.017 + Double(x) * 0.003) + 0.2 * (Double(y) / Double(height))
                pixels[y * bytesPerRow + x] = UInt8(max(0, min(255, v * 255)))
            }
        }
        let cs = CGColorSpaceCreateDeviceGray()
        return pixels.withUnsafeMutableBytes { ptr -> CGImage in
            let ctx = CGContext(
                data: ptr.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue
            )!
            return ctx.makeImage()!
        }
    }

    /// Builds scroll content over a smooth, fixed wallpaper-like horizontal gradient. The
    /// wallpaper is identical at every y; only the content rows move between screenshots.
    private func makeWallpaperContent(width: Int, height: Int) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        var state: UInt64 = 0x123456789ABCDEF0
        for y in 0..<height {
            for x in 0..<width {
                // A fixed horizontal wallpaper gradient plus non-periodic foreground texture.
                // The gradient is identical at every y; only the texture scrolls.
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let wallpaper = 35 + (x * 70 / max(width - 1, 1))
                let foreground = Int((state >> 33) & 0x7F)
                pixels[y * width + x] = UInt8(min(255, wallpaper + foreground))
            }
        }
        let cs = CGColorSpaceCreateDeviceGray()
        return pixels.withUnsafeMutableBytes { ptr -> CGImage in
            let ctx = CGContext(data: ptr.baseAddress, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: width, space: cs,
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            return ctx.makeImage()!
        }
    }

    // MARK: - Tests

    /// Regression: a genuine overlap with a fixed wallpaper must use moving content evidence.
    func testDetectsOverlapWithFixedWallpaper() {
        let width = 64
        let tall = makeWallpaperContent(width: width, height: 900)
        let windowHeight = 360
        let knownOverlap = 140
        let top = crop(tall, startRow: 0, height: windowHeight)
        let bottom = crop(tall, startRow: windowHeight - knownOverlap, height: windowHeight)
        let result = OverlapDetector.detect(top: top, bottom: bottom)

        XCTAssertEqual(result.status, .matched,
                       "Fixed wallpaper must not suppress moving-content evidence")
        XCTAssertEqual(result.overlap, knownOverlap, accuracy: 2)
    }

    /// Regression: a genuine overlap in SMOOTH content must be accepted, not rejected as ambiguous.
    /// Before the non-max-suppression margin fix, adjacent overlaps scored within ~0.001 of the
    /// perfect peak, so the margin gate rejected real matches on photo/screenshot-like content.
    func testDetectsOverlapInSmoothContent() {
        let width = 64
        let tall = makeSmoothImage(width: width, height: 1000)
        let windowHeight = 400
        let knownOverlap = 150
        let top = crop(tall, startRow: 0, height: windowHeight)
        let bottom = crop(tall, startRow: windowHeight - knownOverlap, height: windowHeight)

        let result = OverlapDetector.detect(top: top, bottom: bottom)

        XCTAssertEqual(result.status, .matched,
                       "Smooth-content overlap must be accepted; got \(result.status) \(result.diagnostics)")
        XCTAssertEqual(result.overlap, knownOverlap, accuracy: 2,
                       "Detected overlap must be within ±2px of ground truth")
    }

    /// End-to-end: the engine must stitch a smooth-content overlapping pair into the full height.
    func testEngineStitchesSmoothOverlap() {
        let width = 64
        let tall = makeSmoothImage(width: width, height: 1000)
        let top = crop(tall, startRow: 0, height: 400)
        let bottom = crop(tall, startRow: 250, height: 400) // 150 overlap
        let engine = StitchEngine()
        switch engine.stitchSync(images: [top, bottom]) {
        case .success(let image):
            XCTAssertEqual(image.height, 650, accuracy: 4, "400 + (400 - 150)")
        case .failure(let error):
            XCTFail("Smooth overlap should stitch, got \(error)")
        }
    }

    func testDetectsKnownOverlapWithinTolerance() {
        // A 64-wide tall "scroll source"; two windows into it that overlap by a known amount.
        let width = 64
        let tall = makeImage(width: width, height: 1000, seed: 42)
        let windowHeight = 400
        let knownOverlap = 120

        // Top window: rows [0, 400). Bottom window starts (400 - overlap) → shares 120 rows.
        let top = crop(tall, startRow: 0, height: windowHeight)
        let bottomStart = windowHeight - knownOverlap
        let bottom = crop(tall, startRow: bottomStart, height: windowHeight)

        let result = OverlapDetector.detect(top: top, bottom: bottom)

        XCTAssertEqual(result.status, .matched)
        XCTAssertGreaterThan(result.bestScore, 0.85, "NCC score should be high for a real overlap")
        XCTAssertEqual(result.overlap, knownOverlap, accuracy: 2,
                       "Detected overlap must be within ±2px of ground truth")
    }

    func testNoOverlapForUnrelatedImages() {
        let width = 64
        let a = makeImage(width: width, height: 300, seed: 1)
        let b = makeImage(width: width, height: 300, seed: 9999)
        let result = OverlapDetector.detect(top: a, bottom: b)
        XCTAssertEqual(result.status, .insufficientEvidence, "Unrelated images must not be appended silently")
        XCTAssertEqual(result.overlap, 0)
    }

    func testDuplicateDetection() {
        let width = 64
        let a = makeImage(width: width, height: 300, seed: 7)
        let result = OverlapDetector.detect(top: a, bottom: a)
        XCTAssertTrue(result.status == .duplicate, "Identical images should be flagged as duplicate")
        XCTAssertEqual(result.overlap, a.height)
    }

    func testNormalizedCorrelationIdentity() {
        let v: [Float] = [0.1, 0.5, 0.9, 0.2, 0.7]
        let score = OverlapDetector.normalizedCorrelation(v, v)
        XCTAssertEqual(score, 1.0, accuracy: 1e-4, "NCC of a vector with itself is 1")
    }

    func testNormalizedCorrelationBrightnessInvariance() {
        // Same signal shifted by a constant → NCC should still be ~1 (mean-centered).
        let v: [Float] = [0.1, 0.5, 0.9, 0.2, 0.7]
        let shifted = v.map { $0 + 0.2 }
        let score = OverlapDetector.normalizedCorrelation(v, shifted)
        XCTAssertEqual(score, 1.0, accuracy: 1e-4, "NCC must be invariant to brightness offset")
    }

    // MARK: - Compositor

    func testCompositeProducesExpectedHeight() throws {
        let width = 64
        let a = makeImage(width: width, height: 400, seed: 3)
        let b = makeImage(width: width, height: 400, seed: 4)
        let overlap = 100
        let segments = [
            ImageCompositor.Segment(image: a, overlap: 0),
            ImageCompositor.Segment(image: b, overlap: overlap),
        ]
        let out = try ImageCompositor.composite(segments: segments, width: width)
        XCTAssertEqual(out.width, width)
        XCTAssertEqual(out.height, 400 + (400 - overlap), "Total height = hA + (hB - overlap)")
    }

    /// Pixel-level seam check: stitching two overlapping windows of a known tall image must
    /// reproduce that tall image exactly — no duplicated or dropped rows at the seam.
    /// (A height-only assertion misses off-by-one overlap bugs; this one catches them.)
    func testCompositePreservesContentAcrossSeam() throws {
        let width = 64
        let fullHeight = 680
        let tall = makeImage(width: width, height: fullHeight, seed: 21)

        // Two windows sharing exactly 120 rows: [0,400) and [280,680).
        let overlap = 120
        let top = crop(tall, startRow: 0, height: 400)
        let bottom = crop(tall, startRow: 280, height: 400)

        let out = try ImageCompositor.composite(
            segments: [
                ImageCompositor.Segment(image: top, overlap: 0),
                ImageCompositor.Segment(image: bottom, overlap: overlap),
            ],
            width: width
        )
        XCTAssertEqual(out.height, fullHeight, "Stitched height must match the original tall image")

        // The stitched result must equal the original tall image pixel-for-pixel.
        let expected = grayPixels(tall)
        let actual = grayPixels(out)
        XCTAssertEqual(actual.count, expected.count, "Pixel buffer sizes must match")

        var mismatches = 0
        let n = min(actual.count, expected.count)
        for i in 0..<n where abs(Int(actual[i]) - Int(expected[i])) > 2 {
            mismatches += 1
        }
        // A correct hard-cut stitch reproduces the source near-exactly (no scaling here).
        // An off-by-one seam (duplicated/dropped rows) would mismatch thousands of pixels.
        XCTAssertLessThan(mismatches, n / 100,
                          "Seam must preserve content; \(mismatches)/\(n) pixels differ")
    }

    // MARK: - Engine end to end

    func testEngineStitchesTwoOverlappingImages() {
        let width = 64
        let tall = makeImage(width: width, height: 1000, seed: 11)
        let top = crop(tall, startRow: 0, height: 400)
        let bottom = crop(tall, startRow: 280, height: 400) // 120 overlap

        let engine = StitchEngine()
        var lastProgress = 0.0
        let result = engine.stitchSync(images: [top, bottom]) { lastProgress = $0 }

        switch result {
        case .success(let image):
            // Expected height ≈ 400 + (400 - 120) = 680, within detector tolerance.
            XCTAssertEqual(image.height, 680, accuracy: 4)
            XCTAssertEqual(lastProgress, 1.0, accuracy: 1e-6)
        case .failure(let error):
            XCTFail("Engine should succeed, got \(error)")
        }
    }
}
