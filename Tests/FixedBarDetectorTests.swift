// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
import CoreGraphics
@testable import PostShot

/// Validates `FixedBarDetector` against synthetic frame sequences with known fixed bars.
/// Builds `PixelBuffer`s directly (no CGImage), so it's deterministic and CI-friendly.
final class FixedBarDetectorTests: XCTestCase {

    private let width = PixelBuffer.sampleWidth // 64

    /// Builds a PixelBuffer where rows [0, topBar) and [height-bottomBar, height) are a CONSTANT
    /// pattern shared across frames (the fixed bars), and the middle is filled from `content`
    /// starting at `contentOffset` — simulating a scroll. Same offset on two frames → identical
    /// middle; different offset → differing middle (real scrolling content).
    private func frame(height: Int, topBar: Int, bottomBar: Int, content: [Float], contentOffset: Int) -> PixelBuffer {
        var rows = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let isTop = y < topBar
            let isBottom = y >= height - bottomBar
            for x in 0..<width {
                let idx = y * width + x
                if isTop {
                    rows[idx] = 0.5 // constant top bar
                } else if isBottom {
                    rows[idx] = 0.8 // constant bottom bar
                } else {
                    // scrolling content: sample a tall content strip at this row + offset
                    let c = (contentOffset + y) % content.count
                    rows[idx] = content[c]
                }
            }
        }
        return PixelBuffer(rows: rows, height: height, width: width)
    }

    private func contentStrip(_ n: Int, seed: UInt64) -> [Float] {
        var state = seed &+ 0x9E3779B97F4A7C15
        return (0..<n).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float((state >> 40) & 0xFFFF) / Float(0xFFFF)
        }
    }

    func testDetectsTopAndBottomBars() {
        let height = 200, topBar = 20, bottomBar = 30
        let content = contentStrip(1000, seed: 7)
        // Three frames scrolled by 40 rows each → content differs, bars constant.
        let buffers = [0, 40, 80].map {
            frame(height: height, topBar: topBar, bottomBar: bottomBar, content: content, contentOffset: $0)
        }
        let (top, bottom) = FixedBarDetector.detect(buffers: buffers)
        XCTAssertEqual(top, topBar, accuracy: 2, "Top fixed bar height")
        XCTAssertEqual(bottom, bottomBar, accuracy: 2, "Bottom fixed bar height")
    }

    func testNoBarsWhenEverythingScrolls() {
        let height = 200
        let content = contentStrip(1000, seed: 3)
        let buffers = [0, 40, 80].map {
            frame(height: height, topBar: 0, bottomBar: 0, content: content, contentOffset: $0)
        }
        let (top, bottom) = FixedBarDetector.detect(buffers: buffers)
        XCTAssertEqual(top, 0)
        XCTAssertEqual(bottom, 0)
    }

    func testFractionsCappedAtMax() {
        // A pathological frame that's identical everywhere would report the whole height as fixed;
        // the cap must keep it ≤ maxBandFraction, and the all-fixed guard must zero it out.
        let height = 100
        let content = contentStrip(500, seed: 1)
        // Two IDENTICAL frames (same offset) → every row "fixed".
        let buffers = [0, 0].map {
            frame(height: height, topBar: 10, bottomBar: 10, content: content, contentOffset: $0)
        }
        let (topFrac, bottomFrac) = FixedBarDetector.fractions(forBuffers: buffers)
        // All rows identical → guard returns (0,0) rather than cropping everything.
        XCTAssertEqual(topFrac, 0, "All-identical frames must not crop")
        XCTAssertEqual(bottomFrac, 0)
    }

    func testFractionsConvertCorrectly() {
        let height = 200, topBar = 20, bottomBar = 20
        let content = contentStrip(1000, seed: 9)
        let buffers = [0, 50, 100].map {
            frame(height: height, topBar: topBar, bottomBar: bottomBar, content: content, contentOffset: $0)
        }
        let (topFrac, bottomFrac) = FixedBarDetector.fractions(forBuffers: buffers)
        XCTAssertEqual(topFrac, 0.1, accuracy: 0.02, "20/200 = 0.1")
        XCTAssertEqual(bottomFrac, 0.1, accuracy: 0.02)
    }

    func testSingleFrameYieldsNoBars() {
        let content = contentStrip(500, seed: 2)
        let buffers = [frame(height: 100, topBar: 10, bottomBar: 10, content: content, contentOffset: 0)]
        let (top, bottom) = FixedBarDetector.detect(buffers: buffers)
        XCTAssertEqual(top, 0, "Need ≥2 frames to tell fixed from scrolling")
        XCTAssertEqual(bottom, 0)
    }

    func testToleratesNarrowDynamicIndicatorInTopBar() {
        let height = 200, topBar = 24, bottomBar = 20
        let content = contentStrip(1000, seed: 14)
        var buffers = [0, 45, 90].map {
            frame(height: height, topBar: topBar, bottomBar: bottomBar, content: content, contentOffset: $0)
        }
        // Perturb 4 of 64 columns in the second frame's top status bar (clock / red pill pulse).
        var middleRows = buffers[1].rows
        for y in 2..<14 {
            for x in 4..<8 {
                middleRows[y * width + x] = 0.95
            }
        }
        buffers[1] = PixelBuffer(rows: middleRows, height: height, width: width)

        let (top, bottom) = FixedBarDetector.detect(buffers: buffers)
        XCTAssertEqual(top, topBar, accuracy: 2, "Narrow status-bar clock/pill change must not abort bar detection")
        XCTAssertEqual(bottom, bottomBar, accuracy: 2)
    }

    func testToleratesSingleLeadingTransitionFrameInFiveFrameBurst() {
        let height = 200, topBar = 22, bottomBar = 26
        let content = contentStrip(1200, seed: 19)
        // Frame 0 is an app-switch screen with completely different top/bottom regions.
        let transition = frame(height: height, topBar: 0, bottomBar: 0, content: contentStrip(400, seed: 99), contentOffset: 10)
        let targetFrames = [0, 40, 80, 120].map {
            frame(height: height, topBar: topBar, bottomBar: bottomBar, content: content, contentOffset: $0)
        }

        let (top, bottom) = FixedBarDetector.detect(buffers: [transition] + targetFrames)
        XCTAssertEqual(top, topBar, accuracy: 2, "Single transition pair in 5-frame burst should be tolerated")
        XCTAssertEqual(bottom, bottomBar, accuracy: 2)
    }

    func testToleratesMiddleTransitionFrameAndRejectsNarrowInteriorScroll() {
        let height = 200, topBar = 16, bottomBar = 16
        let content = contentStrip(1200, seed: 25)
        let transition = frame(height: height, topBar: 0, bottomBar: 0, content: contentStrip(400, seed: 88), contentOffset: 5)
        var frames = [0, 40, 80, 120].map {
            frame(height: height, topBar: topBar, bottomBar: bottomBar, content: content, contentOffset: $0)
        }
        // Insert transition frame in the MIDDLE (index 2 of 5).
        frames.insert(transition, at: 2)
        let (top, bottom) = FixedBarDetector.detect(buffers: frames)
        XCTAssertEqual(top, topBar, accuracy: 2, "Middle transition frame in 5-frame burst must be tolerated")
        XCTAssertEqual(bottom, bottomBar, accuracy: 2)

        // Verify narrow scrolling content (4 of 64 cols) below the outer 10% status band is NOT cropped.
        let narrowScrollFrames: [PixelBuffer] = [0, 1, 2].map { idx in
            var rows = [Float](repeating: 0.2, count: width * height)
            // Rows 0..<22 static, row 22 has only 4 scrolling columns (outside outer 10% = 20 rows),
            // rows 30..<180 scroll across full width.
            for x in 28..<32 {
                rows[22 * width + x] = Float(idx) * 0.4
            }
            for y in 30..<180 {
                for x in 0..<width {
                    rows[y * width + x] = content[(y + idx * 35) % content.count]
                }
            }
            return PixelBuffer(rows: rows, height: height, width: width)
        }
        let (narrowTop, _) = FixedBarDetector.detect(buffers: narrowScrollFrames)
        XCTAssertLessThanOrEqual(narrowTop, 22, "Narrow scrolling UI outside status band must stop bar growth")
    }

    func testRejectsMalformedPixelBuffer() {
        let valid = PixelBuffer(rows: [Float](repeating: 0.5, count: width * 100), height: 100, width: width)
        let malformed = PixelBuffer(rows: [0.5], height: 100, width: width)
        let (top, bottom) = FixedBarDetector.detect(buffers: [valid, malformed])
        XCTAssertEqual(top, 0)
        XCTAssertEqual(bottom, 0)
    }

    /// Critical regression: `detectFractions([CGImage])` must measure raw luminance rather than
    /// horizontal-edge deltas so scrolling text/whitespace is NEVER mistaken for a 30% fixed bar!
    func testDetectFractionsOnRealCGImagesDoesNotOverCropTextBody() {
        let imgWidth = 320, imgHeight = 600
        let topBar = 60    // 10%
        let bottomBar = 48 // 8%
        let images: [CGImage] = [0, 110, 220].map { scroll in
            var pixels = [UInt8](repeating: 245, count: imgWidth * imgHeight)
            for y in 0..<imgHeight {
                if y < topBar {
                    let v: UInt8 = (y == topBar - 1) ? 180 : 235
                    for x in 0..<imgWidth { pixels[y * imgWidth + x] = v }
                } else if y >= imgHeight - bottomBar {
                    let v: UInt8 = (y == imgHeight - bottomBar) ? 180 : 230
                    for x in 0..<imgWidth { pixels[y * imgWidth + x] = v }
                } else {
                    // Realistic low-density text lines: 6px dark strokes every 34px on white page.
                    let contentY = y + scroll
                    if contentY % 34 < 6 {
                        for x in 24..<(imgWidth - 36) where (x + contentY) % 5 != 0 {
                            pixels[y * imgWidth + x] = 45
                        }
                    }
                }
            }
            return pixels.withUnsafeMutableBytes { ptr -> CGImage in
                let ctx = CGContext(
                    data: ptr.baseAddress, width: imgWidth, height: imgHeight,
                    bitsPerComponent: 8, bytesPerRow: imgWidth,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
                )!
                return ctx.makeImage()!
            }
        }

        let (topFrac, bottomFrac) = FixedBarDetector.detectFractions(images)
        XCTAssertEqual(topFrac, 0.10, accuracy: 0.02, "Must stop right at the 10% top bar, never 0.30")
        XCTAssertEqual(bottomFrac, 0.08, accuracy: 0.02, "Must stop right at the 8% bottom bar, never 0.30")
    }
}
