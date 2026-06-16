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
}
