// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreMedia
import CoreVideo
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Foundation

/// Converts broadcast `CVPixelBuffer` frames into the two things the extension needs:
/// a cheap grayscale signature (for `FrameSelector`) and full-resolution PNG bytes (for kept frames).
///
/// Memory discipline: the signature path scales in Core Image space and draws into a tiny fixed-size
/// grayscale context (`signatureSize²` bytes), never allocating a full-resolution `CGImage` on
/// skipped frames. Only kept frames pay the full PNG-encode cost and are released immediately.
enum FrameEncoder {

    /// Edge length of the square grayscale signature grid. 64×64 keeps the signature ~4 KB while
    /// preserving enough vertical structure for scroll detection (mirrors PixelBuffer's 64 width).
    static let signatureSize = 64

    /// Builds a downsampled grayscale signature (values 0...1, row-major) from a pixel buffer.
    /// Returns `nil` if a drawing context can't be made. Scales with area/lanczos-quality
    /// downsampling in Core Image space so thin text strokes don't alias across vertical shifts.
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

    /// Encodes a pixel buffer as full-resolution PNG bytes. Only called for KEPT frames.
    static func png(from pixelBuffer: CVPixelBuffer) -> Data? {
        guard let cg = makeCGImage(from: pixelBuffer) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Wraps a `CVPixelBuffer` as a `CGImage` via Core Image. The returned image references the
    /// buffer's pixels for the duration of the call; callers use it synchronously and drop it.
    private static func makeCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        // A shared software context is fine here — frames are infrequent (kept frames only for PNG)
        // and we must avoid Metal/GPU residency growth inside the 50 MB extension budget.
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
