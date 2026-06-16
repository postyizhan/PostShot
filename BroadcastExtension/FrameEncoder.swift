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
/// Memory discipline (SPEC_v2 §2): the signature path draws into a tiny fixed-size grayscale context
/// (`signatureSize²` bytes), never a full-resolution buffer, so every incoming frame is cheap to
/// evaluate. Only frames the selector keeps pay the full PNG-encode cost, and the caller releases
/// them immediately after sending.
enum FrameEncoder {

    /// Edge length of the square grayscale signature grid. 64×64 keeps the signature ~4 KB while
    /// preserving enough vertical structure for scroll detection (mirrors PixelBuffer's 64 width).
    static let signatureSize = 64

    /// Builds a downsampled grayscale signature (values 0...1, row-major) from a pixel buffer.
    /// Returns `nil` if a drawing context can't be made. Cheap: one small CoreGraphics draw.
    static func signature(from pixelBuffer: CVPixelBuffer) -> [Float]? {
        let size = signatureSize
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var gray = [UInt8](repeating: 0, count: size * size)

        let drawn: Bool = gray.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(
                data: ptr.baseAddress, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: size,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
            ), let cg = makeCGImage(from: pixelBuffer) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
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

    /// Reused CIContext. Creating one per frame leaks scratch allocations; one shared software
    /// context keeps footprint flat across a recording.
    private static let sharedContext = CIContext(options: [.useSoftwareRenderer: true])
}
