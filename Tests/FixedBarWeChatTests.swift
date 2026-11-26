// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
import CoreGraphics
@testable import PostShot

/// Real-world regression for screen-recorded WeChat chats: an animating Dynamic Island must not
/// stop nav-bar detection, and a flat `#EDEDED` chat background must not let either band climb
/// into body content. Synthetic grayscale `CGImage`s mimic a 330×717 (≈ iPhone Pro Max) frame.
final class FixedBarWeChatTests: XCTestCase {

    private let w = 330, h = 717
    private let background: UInt8 = 237     // #EDEDED
    private let navSeparator = 89           // last nav row → expected top = 90 (≈ 0.1255)
    private let inputTop = 652              // input bar separator → expected bottom = 65 (≈ 0.0907)
    private let offsets = [0, 143, 286, 429, 572, 715]

    // MARK: - Synthetic frame builder

    private struct Spec {
        var islandWidth = 180
        var islandDot: UInt8 = 200
        var hasNavBar = true
    }

    private func fill(_ px: inout [UInt8], rows: Range<Int>, cols: Range<Int>, _ v: UInt8) {
        for y in rows where y >= 0 && y < h {
            for x in cols where x >= 0 && x < w { px[y * w + x] = v }
        }
    }

    private func drawChrome(_ px: inout [UInt8], _ spec: Spec) {
        fill(&px, rows: 4..<11, cols: 30..<70, 20)                       // clock
        fill(&px, rows: 4..<11, cols: 260..<310, 20)                     // signal / battery
        let x0 = (w - spec.islandWidth) / 2                              // Dynamic Island
        fill(&px, rows: 13..<39, cols: x0..<(x0 + spec.islandWidth), 0)
        fill(&px, rows: 22..<30, cols: (x0 + 12)..<(x0 + 22), spec.islandDot)
        if spec.hasNavBar {
            fill(&px, rows: 60..<76, cols: 10..<24, 30)                  // back chevron
            fill(&px, rows: 60..<76, cols: 120..<210, 30)                // title "潘俊东"
            fill(&px, rows: navSeparator..<(navSeparator + 1), cols: 0..<w, 200)
        }
        fill(&px, rows: inputTop..<(inputTop + 1), cols: 0..<w, 200)     // input separator
        fill(&px, rows: (inputTop + 1)..<h, cols: 0..<w, 246)            // input bar
        fill(&px, rows: 665..<695, cols: 50..<270, 210)                  // input box outline
        fill(&px, rows: 667..<693, cols: 52..<268, 255)
        fill(&px, rows: 705..<709, cols: 110..<220, 20)                  // Home indicator
    }

    /// Sparse left-aligned bubbles scroll inside `body`; everything else stays flat background.
    private func drawBody(_ px: inout [UInt8], offset: Int, body: Range<Int>) {
        for y in body {
            let c = (y + offset) % 120
            guard c < 40 else { continue }
            fill(&px, rows: y..<(y + 1), cols: 40..<160, 255)            // bubble
            if c < 30 { fill(&px, rows: y..<(y + 1), cols: 8..<36, 150) } // avatar
        }
    }

    private func makeImage(_ px: [UInt8], width: Int? = nil) -> CGImage {
        var pixels = px
        return pixels.withUnsafeMutableBytes { ptr -> CGImage in
            let ctx = CGContext(
                data: ptr.baseAddress, width: width ?? w, height: h,
                bitsPerComponent: 8, bytesPerRow: width ?? w,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            )!
            return ctx.makeImage()!
        }
    }

    /// 6-frame recording: island morphs over the first 3 frames (hotspot → transition → recording
    /// pill), then stays. Body rows 90..<110 and 430..<652 are flat in every frame.
    private func recordingFrames(hasNavBar: Bool = true) -> [CGImage] {
        let islands: [(Int, UInt8)] = [(110, 90), (250, 60), (180, 200), (180, 200), (180, 200), (180, 200)]
        return zip(offsets, islands).map { offset, island in
            var px = [UInt8](repeating: background, count: w * h)
            let spec = Spec(islandWidth: island.0, islandDot: island.1, hasNavBar: hasNavBar)
            drawBody(&px, offset: offset, body: hasNavBar ? 110..<430 : 47..<430)
            drawChrome(&px, spec)
            return makeImage(px)
        }
    }

    // MARK: - Tests

    func testDynamicIslandAnimationDoesNotBlockNavBarDetection() {
        let (top, _) = FixedBarDetector.detectFractions(recordingFrames())
        XCTAssertEqual(top, Float(navSeparator + 1) / Float(h), accuracy: 0.01,
                       "Must reach the nav separator (≈0.125), not stop at the island (≈0.02)")
    }

    func testBottomDoesNotClimbIntoFlatChatBackground() {
        let (_, bottom) = FixedBarDetector.detectFractions(recordingFrames())
        XCTAssertEqual(bottom, Float(h - inputTop) / Float(h), accuracy: 0.01,
                       "Must stop at the input bar separator (≈0.09), never climb to 0.18")
    }

    func testRecordingFloorCropsStatusBandWithoutNavBar() {
        let frames = recordingFrames(hasNavBar: false)
        let (rawTop, _) = FixedBarDetector.detectFractions(frames)
        XCTAssertLessThan(rawTop, FixedBarDetector.recordingStatusBandFloor, "No nav bar → island stops detection")
        let (top, _) = FixedBarDetector.detectFractions(
            frames, minimumTopFraction: FixedBarDetector.recordingStatusBandFloor
        )
        XCTAssertEqual(top, FixedBarDetector.recordingStatusBandFloor, accuracy: 0.002)
    }

    func testNonPortraitImagesSkipStatusBandLogic() {
        // Same frames padded to 500 wide (h/w ≈ 1.43 < 2.0): strict scan only, island stops it.
        let wide = 500
        let frames = recordingFrames().map { image -> CGImage in
            let ctx = CGContext(
                data: nil, width: wide, height: h, bitsPerComponent: 8, bytesPerRow: wide,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            )!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: wide, height: h))
            return ctx.makeImage()!
        }
        let (top, _) = FixedBarDetector.detectFractions(frames)
        XCTAssertLessThan(top, 0.05, "Status-band skip must only apply to full-screen portrait frames")
    }

    func testShrinkStopsAtSeparatorLine() {
        let width = PixelBuffer.sampleWidth, height = 200
        // Rows 0..<19 bar (0.5), row 19 separator (0.3), rows 20..<60 flat background (0.9) in
        // every frame, rows 60..<200 full-width scrolling stripes.
        let buffers: [PixelBuffer] = [0, 37, 74].map { offset in
            var rows = [Float](repeating: 0.9, count: width * height)
            for y in 0..<height {
                let v: Float
                switch y {
                case 0..<19: v = 0.5
                case 19: v = 0.3
                case 20..<60: v = 0.9
                default: v = ((y + offset) / 7) % 2 == 0 ? 0.1 : 0.9
                }
                for x in 0..<width { rows[y * width + x] = v }
            }
            return PixelBuffer(rows: rows, height: height, width: width)
        }
        let (top, _) = FixedBarDetector.detect(buffers: buffers)
        XCTAssertEqual(top, 20, "Band must retreat from the flat background to just below the separator")
    }
}
