// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreGraphics
import Foundation

/// Detects fixed UI bars (status bar / nav bar / bottom input bar) across a burst of screenshots,
/// so they can be auto-cropped before stitching — the Tailor-style "no manual sliders" experience.
///
/// KEY INSIGHT: within one session the screenshots are pixel-identical wherever content overlaps,
/// and a FIXED bar sits at the same screen position in every shot — so row `y` of the bar is
/// identical across all frames, while scrolling content at row `y` differs from frame to frame.
/// A fixed band is therefore the maximal run of rows, anchored at the top or bottom edge, that
/// stays identical across every consecutive frame pair.
///
/// Pure and unit-testable: the core works on `PixelBuffer`s (downsampled 64-wide grayscale rows),
/// so synthetic sequences with known bars validate it on CI without real images.
enum FixedBarDetector {

    struct Config {
        /// Per-row raw-luminance mean-abs-diff (0...1) below which two rows count as identical.
        var rowMatchThreshold: Float = 0.015
        /// Cap on automatically suggested band fraction so whitespace margins can never eat body
        /// content (manual sliders still allow up to 30% when dragged explicitly).
        var maxBandFraction: Float = 0.18
        /// Fraction of highest-diff columns trimmed inside the outer status/home-indicator bands
        /// (`<= 10%` from top/bottom) when `width >= 32`, absorbing narrow clock or recording-pill
        /// changes without letting narrow scrolling content inside the body look fixed.
        var statusBandTrimColumnFraction: Float = 0.09

        init() {}
    }

    /// Crop fractions (top, bottom), 0...maxBandFraction, for `StitchEngine.Options`.
    ///
    /// IMPORTANT: Builds raw grayscale luminance buffers rather than `PixelBuffer.from(_:)`
    /// (which stores tiny horizontal-edge deltas ~0.005 that would underflow `rowMatchThreshold`
    /// and falsely classify scrolling text/whitespace as fixed bars).
    static func detectFractions(_ images: [CGImage], config: Config = Config()) -> (top: Float, bottom: Float) {
        let buffers = images.compactMap { luminanceBuffer(from: $0) }
        guard buffers.count == images.count else { return (0, 0) }
        return fractions(forBuffers: buffers, config: config)
    }

    /// Downsamples `image` horizontally to `sampleWidth` raw grayscale luminance samples (0...1)
    /// at full vertical resolution for fixed-bar comparison.
    static func luminanceBuffer(from image: CGImage, sampleWidth: Int = PixelBuffer.sampleWidth) -> PixelBuffer? {
        let height = image.height
        guard height > 0, sampleWidth > 0, sampleWidth <= Int.max / height else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 0, count: sampleWidth * height)
        let ok: Bool = pixels.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(
                data: ptr.baseAddress,
                width: sampleWidth,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: sampleWidth,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: height))
            return true
        }
        guard ok else { return nil }
        let rows = pixels.map { Float($0) / 255.0 }
        return PixelBuffer(rows: rows, height: height, width: sampleWidth)
    }

    /// Raw fixed-band row counts (top, bottom) across the frame sequence.
    static func detect(buffers: [PixelBuffer], config: Config = Config()) -> (topRows: Int, bottomRows: Int) {
        guard buffers.count >= 2 else { return (0, 0) }
        let width = buffers[0].width, height = buffers[0].height
        guard width > 0, height > 0,
              buffers.allSatisfy({ $0.isStructurallyValid && $0.width == width && $0.height == height }) else {
            return (0, 0)
        }

        var top = 0
        while top < height && rowFixed(top, height: height, buffers, config) { top += 1 }

        var bottom = 0
        while bottom < height && rowFixed(height - 1 - bottom, height: height, buffers, config) { bottom += 1 }

        return (top, bottom)
    }

    /// Applies the cap and the all-fixed guard, converting row counts to fractions.
    static func fractions(forBuffers buffers: [PixelBuffer], config: Config = Config()) -> (top: Float, bottom: Float) {
        let (top, bottom) = detect(buffers: buffers, config: config)
        guard let height = buffers.first?.height, height > 0 else { return (0, 0) }
        // Everything matched → frames are duplicates / no scroll; cropping would be meaningless.
        guard top + bottom < height else { return (0, 0) }
        let topFrac = min(Float(top) / Float(height), config.maxBandFraction)
        let bottomFrac = min(Float(bottom) / Float(height), config.maxBandFraction)
        return (topFrac, bottomFrac)
    }

    /// True iff row `y` matches across all frames (for 2–4 frames) or all-but-one frame (for >= 5
    /// frames, tolerating a single transition frame anywhere at the start, middle, or end).
    private static func rowFixed(_ y: Int, height: Int, _ buffers: [PixelBuffer], _ config: Config) -> Bool {
        let count = buffers.count
        let requiredMatches = count >= 5 ? (count - 1) : count
        let trimColumns = isOuterSystemBand(y: y, height: height)
        for refIndex in [0, 1] where refIndex < count {
            var matches = 0
            for i in 0..<count {
                if i == refIndex || rowDiff(buffers[refIndex], buffers[i], y, trimColumns: trimColumns, config) <= config.rowMatchThreshold {
                    matches += 1
                }
            }
            if matches >= requiredMatches { return true }
            if requiredMatches == count { break }
        }
        return false
    }

    private static func isOuterSystemBand(y: Int, height: Int) -> Bool {
        let margin = max(1, height / 10)
        return y < margin || y >= height - margin
    }

    /// Mean absolute difference between row `y` of two buffers, trimming narrow outlier columns
    /// only within the outer system status / Home-indicator bands.
    private static func rowDiff(
        _ a: PixelBuffer, _ b: PixelBuffer, _ y: Int, trimColumns: Bool, _ config: Config
    ) -> Float {
        let aRow = a.row(y), bRow = b.row(y)
        let n = min(aRow.count, bRow.count)
        guard n > 0 else { return 0 }
        let aBase = aRow.startIndex, bBase = bRow.startIndex
        let frac = config.statusBandTrimColumnFraction.isFinite ? max(0, min(config.statusBandTrimColumnFraction, 0.2)) : 0
        let trimCount = (trimColumns && n >= 32) ? Int((Float(n) * frac).rounded(.down)) : 0
        guard trimCount > 0, trimCount < n else {
            var sum: Float = 0
            for i in 0..<n { sum += abs(aRow[aBase + i] - bRow[bBase + i]) }
            return sum / Float(n)
        }
        var diffs = [Float](repeating: 0, count: n)
        for i in 0..<n { diffs[i] = abs(aRow[aBase + i] - bRow[bBase + i]) }
        diffs.sort()
        let keepCount = n - trimCount
        var sum: Float = 0
        for i in 0..<keepCount { sum += diffs[i] }
        return sum / Float(keepCount)
    }
}
