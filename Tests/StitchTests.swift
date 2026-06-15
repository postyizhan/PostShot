// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
import CoreGraphics
@testable import PostShot

/// Validates `OverlapDetector` against synthetic images with a known overlap (SPEC §9).
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

    // MARK: - Tests

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

        XCTAssertGreaterThan(result.score, 0.85, "NCC score should be high for a real overlap")
        XCTAssertEqual(result.overlap, knownOverlap, accuracy: 2,
                       "Detected overlap must be within ±2px of ground truth (SPEC §9)")
    }

    func testNoOverlapForUnrelatedImages() {
        let width = 64
        let a = makeImage(width: width, height: 300, seed: 1)
        let b = makeImage(width: width, height: 300, seed: 9999)
        let result = OverlapDetector.detect(top: a, bottom: b)
        XCTAssertEqual(result.overlap, 0, "Unrelated images should report no overlap")
    }

    func testDuplicateDetection() {
        let width = 64
        let a = makeImage(width: width, height: 300, seed: 7)
        let result = OverlapDetector.detect(top: a, bottom: a)
        XCTAssertTrue(result.isDuplicate, "Identical images should be flagged as duplicate")
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
