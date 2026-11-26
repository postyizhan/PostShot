// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
import CoreGraphics
@testable import PostShot

final class ScreenshotSequenceOrdererTests: XCTestCase {
    private func makeImage(width: Int, height: Int, seed: UInt64) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        var state = seed
        for y in 0..<height {
            for x in 0..<width {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                pixels[y * width + x] = UInt8((state >> 33) & 0xFF)
            }
        }
        let cs = CGColorSpaceCreateDeviceGray()
        return pixels.withUnsafeMutableBytes { ptr in
            let context = CGContext(data: ptr.baseAddress, width: width, height: height,
                                    bitsPerComponent: 8, bytesPerRow: width, space: cs,
                                    bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            return context.makeImage()!
        }
    }

    private func crop(_ image: CGImage, start: Int, height: Int) -> CGImage {
        image.cropping(to: CGRect(x: 0, y: start, width: image.width, height: height))!
    }

    func testRecoversOrderFromShuffledOverlappingWindows() {
        let source = makeImage(width: 64, height: 1120, seed: 42)
        let windows = [
            crop(source, start: 0, height: 400),
            crop(source, start: 280, height: 400),
            crop(source, start: 560, height: 400),
            crop(source, start: 720, height: 400)
        ]
        let shuffled = [windows[2], windows[0], windows[3], windows[1]]
        let order = ScreenshotSequenceOrderer.order(
            images: shuffled,
            topCropFraction: 0,
            bottomCropFraction: 0
        )
        XCTAssertEqual(order, [1, 3, 0, 2])
    }

    func testRejectsBatchWithoutCompleteMatchedChain() {
        let a = makeImage(width: 64, height: 300, seed: 1)
        let b = makeImage(width: 64, height: 300, seed: 2)
        let c = makeImage(width: 64, height: 300, seed: 3)
        XCTAssertNil(ScreenshotSequenceOrderer.order(
            images: [a, b, c], topCropFraction: 0, bottomCropFraction: 0
        ))
    }

    func testExcludesControlCenterOutlierAndOrdersRemainingScreenshots() {
        let source = makeImage(width: 64, height: 1120, seed: 99)
        let w0 = crop(source, start: 0, height: 400)
        let w1 = crop(source, start: 260, height: 400)
        let w2 = crop(source, start: 520, height: 400)
        let outlier = makeImage(width: 64, height: 400, seed: 777_777)
        let mixed = [w2, outlier, w0, w1]

        let order = ScreenshotSequenceOrderer.order(
            images: mixed, topCropFraction: 0, bottomCropFraction: 0
        )
        XCTAssertEqual(order, [2, 3, 0], "Must drop unrelated outlier at index 1 and recover w0→w1→w2")
    }
}
