// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreGraphics
import XCTest
@testable import PostShot

/// Regression coverage for high-overlap (`95%..<100%`) micro-scrolls and noisy near-duplicate
/// frames produced by ReplayKit screen-recording capture.
final class HighOverlapStitchTests: XCTestCase {

    private func makeImage(width: Int, height: Int, seed: UInt64) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        var state = seed &+ 0x9E3779B97F4A7C15
        func next() -> UInt8 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8((state >> 33) & 0xFF)
        }
        for y in 0..<height {
            let rowBase = UInt8((y &* 37) & 0xFF)
            for x in 0..<width {
                pixels[y * width + x] = rowBase &+ (next() & 0x3F)
            }
        }
        return makeGrayCGImage(pixels: &pixels, width: width, height: height)
    }

    private func makeSmoothImage(width: Int, height: Int) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let v = 0.5 + 0.25 * sin(Double(y) * 0.017 + Double(x) * 0.003) + 0.2 * (Double(y) / Double(height))
                pixels[y * width + x] = UInt8(max(0, min(255, v * 255)))
            }
        }
        return makeGrayCGImage(pixels: &pixels, width: width, height: height)
    }

    private func makeGrayCGImage(pixels: inout [UInt8], width: Int, height: Int) -> CGImage {
        pixels.withUnsafeMutableBytes { ptr -> CGImage in
            let ctx = CGContext(
                data: ptr.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            )!
            return ctx.makeImage()!
        }
    }

    private func crop(_ source: CGImage, startRow: Int, height: Int) -> CGImage {
        source.cropping(to: CGRect(x: 0, y: startRow, width: source.width, height: height))!
    }

    private func grayPixels(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h)
        pixels.withUnsafeMutableBytes { ptr in
            let ctx = CGContext(
                data: ptr.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            )!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return pixels
    }

    func testDetectsHighOverlap96And98Percent() {
        let width = 64
        let textured = makeImage(width: width, height: 1000, seed: 77)
        let smooth = makeSmoothImage(width: width, height: 1000)
        let windowHeight = 400

        for knownOverlap in [384, 392] {
            let start = windowHeight - knownOverlap
            let texResult = OverlapDetector.detect(
                top: crop(textured, startRow: 0, height: windowHeight),
                bottom: crop(textured, startRow: start, height: windowHeight)
            )
            XCTAssertEqual(texResult.status, .matched)
            XCTAssertEqual(texResult.overlap, knownOverlap, accuracy: 2)

            let smoothResult = OverlapDetector.detect(
                top: crop(smooth, startRow: 0, height: windowHeight),
                bottom: crop(smooth, startRow: start, height: windowHeight)
            )
            XCTAssertEqual(smoothResult.status, .matched)
            XCTAssertEqual(smoothResult.overlap, knownOverlap, accuracy: 2)
        }
    }

    func testDetects99PercentMicroScrollOverlapAndStitches() {
        let width = 64, windowHeight = 400, knownOverlap = 396
        let tall = makeImage(width: width, height: 1000, seed: 81)
        let top = crop(tall, startRow: 0, height: windowHeight)
        let bottom = crop(tall, startRow: windowHeight - knownOverlap, height: windowHeight)

        let match = OverlapDetector.detect(top: top, bottom: bottom)
        XCTAssertEqual(match.status, .matched)
        XCTAssertEqual(match.overlap, knownOverlap, accuracy: 2)

        switch StitchEngine().stitchSync(images: [top, bottom]) {
        case .success(let image):
            XCTAssertEqual(image.height, 404, accuracy: 4)
        case .failure(let error):
            XCTFail("99% overlap pair must stitch without unsafeSeam, got \(error)")
        }
    }

    func testNearDuplicateWithLocalizedStatusNoiseIsSkippedAsDuplicate() {
        let width = 64, windowHeight = 400
        let tall = makeImage(width: width, height: 900, seed: 88)
        let first = crop(tall, startRow: 0, height: windowHeight)
        var noisyPixels = grayPixels(first)
        for y in 2..<14 {
            for x in 4..<14 {
                noisyPixels[y * width + x] = noisyPixels[y * width + x] &+ 120
            }
        }
        let noisySecond = makeGrayCGImage(pixels: &noisyPixels, width: width, height: windowHeight)
        let third = crop(tall, startRow: 120, height: windowHeight)

        let bufA = PixelBuffer.from(first)!
        let bufB = PixelBuffer.from(noisySecond)!
        let fullScore = OverlapDetector.nccScore(aTail: bufA, bHead: bufB, overlap: windowHeight)
        XCTAssertLessThan(fullScore, 0.995)
        XCTAssertGreaterThanOrEqual(fullScore, 0.92)
        XCTAssertEqual(OverlapDetector.detect(top: first, bottom: noisySecond).status, .duplicate)

        switch StitchEngine().stitchSync(images: [first, noisySecond, third]) {
        case .success(let image):
            XCTAssertEqual(image.height, 520, accuracy: 4)
        case .failure(let error):
            XCTFail("Near-duplicate frame should be skipped cleanly, got \(error)")
        }
    }

    func testCeilingMicroScrollBeatsLowerPeriodicCardPeak() {
        let width = 64, totalHeight = 600, windowHeight = 400
        var pixels = [UInt8](repeating: 240, count: width * totalHeight)
        var rng: UInt64 = 0xCAFEBABE12345678
        func nextByte() -> UInt8 {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return UInt8((rng >> 33) & 0x7F)
        }
        var template = [UInt8](repeating: 0, count: width * 180)
        for i in 0..<template.count { template[i] = nextByte() }
        for y in 0..<totalHeight {
            let ty = y % 180
            for x in 0..<width {
                let unique = (x >= 48) ? (nextByte() / 2) : 0
                pixels[y * width + x] = template[ty * width + x] &+ unique
            }
        }
        let tall = makeGrayCGImage(pixels: &pixels, width: width, height: totalHeight)
        let top = crop(tall, startRow: 0, height: windowHeight)
        let bottom = crop(tall, startRow: 4, height: windowHeight)

        let result = OverlapDetector.detect(top: top, bottom: bottom)
        XCTAssertEqual(result.status, .matched)
        XCTAssertEqual(result.overlap, 396, accuracy: 2)
    }
}
