// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreGraphics
import Foundation

/// Downsampled grayscale row-feature buffer for a single image.
///
/// Each image row is reduced to `sampleWidth` grayscale samples (SPEC §2.1 step 1).
/// Comparing these "row signatures" is sufficient and fast for pure vertical scroll.
struct PixelBuffer {

    /// Number of horizontal samples per row.
    static let sampleWidth = 64

    /// Row-major grayscale samples, `height` rows of `sampleWidth` values each, normalized 0...1.
    let rows: [Float]
    let height: Int
    let width: Int

    /// Per-row mean grayscale, length == height. Used by the 1D coarse search (SPEC §2.1 step 2).
    let rowMeans: [Float]

    init(rows: [Float], height: Int, width: Int) {
        self.rows = rows
        self.height = height
        self.width = width
        var means = [Float](repeating: 0, count: height)
        let w = Float(width)
        for y in 0..<height {
            var sum: Float = 0
            let base = y * width
            for x in 0..<width { sum += rows[base + x] }
            means[y] = sum / w
        }
        self.rowMeans = means
    }

    /// Returns the contiguous grayscale samples for row `y` (length == width).
    func row(_ y: Int) -> ArraySlice<Float> {
        let base = y * width
        return rows[base..<(base + width)]
    }
}

extension PixelBuffer {

    /// Builds a `PixelBuffer` from a `CGImage`, downsampling each row to `sampleWidth` samples.
    ///
    /// Draws the image into a `sampleWidth`-wide grayscale context (Core Graphics handles the
    /// horizontal averaging) at full vertical resolution, then reads back luminance.
    static func from(_ image: CGImage, sampleWidth: Int = PixelBuffer.sampleWidth) -> PixelBuffer? {
        let height = image.height
        guard height > 0, sampleWidth > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bytesPerRow = sampleWidth
        var pixels = [UInt8](repeating: 0, count: sampleWidth * height)

        let success: Bool = pixels.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(
                data: ptr.baseAddress,
                width: sampleWidth,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: height))
            return true
        }
        guard success else { return nil }

        // Core Graphics origin is bottom-left; flip to top-down row order.
        var rows = [Float](repeating: 0, count: sampleWidth * height)
        for y in 0..<height {
            let srcBase = (height - 1 - y) * bytesPerRow
            let dstBase = y * sampleWidth
            for x in 0..<sampleWidth {
                rows[dstBase + x] = Float(pixels[srcBase + x]) / 255.0
            }
        }
        return PixelBuffer(rows: rows, height: height, width: sampleWidth)
    }
}
