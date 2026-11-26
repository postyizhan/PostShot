// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreMedia
import CoreVideo
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Foundation

/// Converts broadcast `CVPixelBuffer` frames into the two things the extension needs:
/// a cheap grayscale signature (for `FrameSelector`) and high-quality compressed image bytes.
///
/// Memory discipline: the signature path scales in Core Image space and draws into a tiny fixed-size
/// grayscale context (`signatureSize²` bytes), never allocating a full-resolution `CGImage` on
/// skipped frames. Kept frames encode via quality-0.95 JPEG (4:4:4 chroma in ImageIO, ~8× faster
/// and ~8× smaller than zlib PNG) and are released immediately.
enum FrameEncoder {

    /// Edge length of the square grayscale signature grid. 64×64 keeps the signature ~4 KB while
    /// preserving enough vertical structure for scroll detection (mirrors PixelBuffer's 64 width).
    static let signatureSize = 64

    /// Builds a downsampled grayscale signature (values 0...1, row-major) from a pixel buffer.
    static func signature(from pixelBuffer: CVPixelBuffer) -> [Float]? {
        let size = signatureSize
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: size, height: size)
        let transform = CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y)
            .scaledBy(x: CGFloat(size) / extent.width, y: CGFloat(size) / extent.height)
        let scaled = ciImage
            .clampedToExtent()
            .transformed(by: transform, highQualityDownsample: true)
            .cropped(to: bounds)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var gray = [UInt8](repeating: 0, count: size * size)

        let drawn: Bool = gray.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(
                data: ptr.baseAddress, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: size,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
            ), let cg = sharedContext.createCGImage(scaled, from: bounds) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(cg, in: bounds)
            return true
        }
        guard drawn else { return nil }
        return gray.map { Float($0) / 255.0 }
    }

    /// Encodes a pixel buffer as high-quality JPEG (`quality = 0.95`, 4:4:4 crisp text edges) for
    /// fast, low-memory loopback streaming into the host app's disk frame pool.
    static func encodedFrame(from pixelBuffer: CVPixelBuffer, quality: CGFloat = 0.95) -> Data? {
        guard let cg = makeCGImage(from: pixelBuffer) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, cg, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private static func makeCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        return sharedContext.createCGImage(ciImage, from: ciImage.extent)
    }

    /// Reused software CIContext with intermediate caching disabled to keep memory flat under
    /// ReplayKit's ~50 MB process limit.
    private static let sharedContext = CIContext(options: [
        .useSoftwareRenderer: true,
        .cacheIntermediates: false,
        .highQualityDownsample: true,
    ])
}
