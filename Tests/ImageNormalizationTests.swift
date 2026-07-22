// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PostShot

final class ImageNormalizationTests: XCTestCase {
    private func bandedImage(width: Int = 4, height: Int = 10) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let color: (UInt8, UInt8, UInt8) = y < 2 ? (255, 0, 0) : (0, 0, 255)
            for x in 0..<width {
                let index = (y * width + x) * 4
                pixels[index] = color.0
                pixels[index + 1] = color.1
                pixels[index + 2] = color.2
                pixels[index + 3] = 255
            }
        }
        return pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            return context.makeImage()!
        }
    }

    private func rgba(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(
                data: bytes.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    private func firstPixel(_ image: CGImage) -> (UInt8, UInt8, UInt8) {
        pixel(image, x: 0, y: 0)
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
        let pixels = rgba(image)
        let index = (y * image.width + x) * 4
        return (pixels[index], pixels[index + 1], pixels[index + 2])
    }

    private func cornerImage() -> CGImage {
        let width = 2, height = 3
        let colors: [(UInt8, UInt8, UInt8)] = [
            (255, 0, 0), (0, 255, 0),
            (0, 0, 0), (0, 0, 0),
            (0, 0, 255), (255, 255, 0),
        ]
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for (index, color) in colors.enumerated() {
            let offset = index * 4
            pixels[offset] = color.0
            pixels[offset + 1] = color.1
            pixels[offset + 2] = color.2
            pixels[offset + 3] = 255
        }
        return pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            return context.makeImage()!
        }
    }

    private func encode(_ image: CGImage, orientation: Int) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        let properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testVisualTopCropRemovesTopBand() throws {
        let cropped = try ImageNormalizer.crop(bandedImage(), topFraction: 0.2, bottomFraction: 0)
        XCTAssertEqual(cropped.height, 8)
        let pixel = firstPixel(cropped)
        XCTAssertLessThan(pixel.0, 20)
        XCTAssertGreaterThan(pixel.2, 230)
    }

    func testVisualBottomCropKeepsTopBand() throws {
        let cropped = try ImageNormalizer.crop(bandedImage(), topFraction: 0, bottomFraction: 0.2)
        XCTAssertEqual(cropped.height, 8)
        let pixel = firstPixel(cropped)
        XCTAssertGreaterThan(pixel.0, 230)
        XCTAssertLessThan(pixel.2, 20)
    }

    func testCropRejectsNonFiniteFractions() {
        XCTAssertThrowsError(try ImageNormalizer.crop(bandedImage(), topFraction: .nan, bottomFraction: 0))
        XCTAssertThrowsError(try ImageNormalizer.crop(bandedImage(), topFraction: 0, bottomFraction: .infinity))
    }

    func testEncodedOrientationSwapsDimensionsForSixAndEight() throws {
        let image = bandedImage(width: 4, height: 10)
        for orientation in [6, 8] {
            let output = try ImageNormalizer.normalize(data: encode(image, orientation: orientation))
            XCTAssertEqual(output.image.width, 10)
            XCTAssertEqual(output.image.height, 4)
            XCTAssertEqual(output.diagnostics.orientation, orientation)
        }
    }

    func testOrientationOverrideUsesAuthoritativeMetadata() throws {
        let encodedAsOne = encode(cornerImage(), orientation: 1)
        let output = try ImageNormalizer.normalize(data: encodedAsOne, orientationOverride: 6)

        XCTAssertEqual(output.image.width, 3)
        XCTAssertEqual(output.image.height, 2)
        XCTAssertEqual(output.diagnostics.orientation, 6)
        // Orientation 6 is a 90° clockwise display transform: source bottom-left becomes top-left.
        let topLeft = pixel(output.image, x: 0, y: 0)
        XCTAssertLessThan(topLeft.0, 20)
        XCTAssertLessThan(topLeft.1, 20)
        XCTAssertGreaterThan(topLeft.2, 230)
    }

    func testOrientationThreeMovesBottomRightToTopLeft() throws {
        let output = try ImageNormalizer.normalize(data: encode(cornerImage(), orientation: 3))
        let topLeft = pixel(output.image, x: 0, y: 0)
        XCTAssertGreaterThan(topLeft.0, 230)
        XCTAssertGreaterThan(topLeft.1, 230)
        XCTAssertLessThan(topLeft.2, 20)
    }

    func testEncodedOrientationOnePreservesDimensionsAndCanonicalColorSpace() throws {
        let output = try ImageNormalizer.normalize(data: encode(bandedImage(), orientation: 1))
        XCTAssertEqual(output.image.width, 4)
        XCTAssertEqual(output.image.height, 10)
        XCTAssertEqual(output.image.colorSpace?.name, CGColorSpace.sRGB)
        XCTAssertEqual(output.image.bitsPerComponent, 8)
    }

    func testCorruptDataFailsNormalization() {
        XCTAssertThrowsError(try ImageNormalizer.normalize(data: Data([0, 1, 2, 3])))
    }
}
