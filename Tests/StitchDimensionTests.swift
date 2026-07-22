// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreGraphics
import XCTest
@testable import PostShot

final class StitchDimensionTests: XCTestCase {
    private func image(width: Int, height: Int, value: UInt8 = 127) -> CGImage {
        var pixels = [UInt8](repeating: value, count: width * height)
        return pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )!
            return context.makeImage()!
        }
    }

    func testValidatorAcceptsEqualDimensions() {
        let profile = StitchInputValidator.validate([
            image(width: 64, height: 100),
            image(width: 64, height: 100),
        ])

        XCTAssertTrue(profile.isValid)
        XCTAssertEqual(profile.canonicalSize, PixelSize(width: 64, height: 100))
    }

    func testValidatorReportsAllDimensionMismatches() {
        let profile = StitchInputValidator.validate([
            image(width: 64, height: 100),
            image(width: 63, height: 100),
            image(width: 64, height: 99),
        ])

        XCTAssertFalse(profile.isValid)
        XCTAssertEqual(profile.diagnostics.map(\.sourceIndex), [1, 2])
        XCTAssertTrue(profile.diagnostics.allSatisfy { $0.reason == .dimensionMismatch })
    }

    func testDetectorRejectsMalformedAndUnequalBuffers() {
        let valid = PixelBuffer(rows: [Float](repeating: 0.5, count: 64 * 20), height: 20, width: 64)
        let narrow = PixelBuffer(rows: [Float](repeating: 0.5, count: 32 * 20), height: 20, width: 32)
        let malformed = PixelBuffer(rows: [0.5], height: 20, width: 64)

        XCTAssertEqual(OverlapDetector.detect(top: valid, bottom: narrow).status, .invalidInput)
        XCTAssertEqual(OverlapDetector.detect(top: narrow, bottom: valid).status, .invalidInput)
        XCTAssertEqual(OverlapDetector.detect(top: valid, bottom: malformed).status, .invalidInput)
    }

    func testEngineRejectsMixedDimensionsBeforeComposition() {
        let result = StitchEngine().stitchSync(images: [
            image(width: 64, height: 100),
            image(width: 63, height: 100),
        ])

        guard case .failure(.invalidInput(let profile)) = result else {
            return XCTFail("Mixed dimensions must fail preflight")
        }
        XCTAssertEqual(profile.diagnostics.map(\.sourceIndex), [1])
    }

    func testEngineStopsOnInsufficientEvidence() {
        let result = StitchEngine().stitchSync(images: [
            image(width: 64, height: 100, value: 80),
            image(width: 64, height: 100, value: 120),
        ])

        guard case .failure(.unsafeSeam(let seam)) = result else {
            return XCTFail("Low-information seam must not produce an output image")
        }
        XCTAssertEqual(seam.topIndex, 0)
        XCTAssertEqual(seam.bottomIndex, 1)
        XCTAssertEqual(seam.result.status, .insufficientEvidence)
    }

    func testDetectorRequiresAtLeastTwoCandidatesForUniqueness() {
        var config = OverlapDetector.Config()
        config.candidateCount = 1
        let buffer = PixelBuffer(rows: (0..<(64 * 100)).map { Float(($0 * 37) % 255) / 255 }, height: 100, width: 64)

        XCTAssertEqual(OverlapDetector.detect(top: buffer, bottom: buffer, config: config).status, .invalidInput)
    }
}
