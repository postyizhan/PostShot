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
        /// Per-row mean-abs-diff (0...1) below which two rows count as identical. Small, because
        /// true fixed bars are exact; a little slack absorbs downsample/JPEG noise.
        var rowMatchThreshold: Float = 0.02
        /// Never crop more than this fraction off either end (matches the manual slider cap), so a
        /// misdetection can't eat real content.
        var maxBandFraction: Float = 0.3

        init() {}
    }

    /// Crop fractions (top, bottom), 0...maxBandFraction, for `StitchEngine.Options`.
    static func detectFractions(_ images: [CGImage], config: Config = Config()) -> (top: Float, bottom: Float) {
        let buffers = images.compactMap { PixelBuffer.from($0) }
        guard buffers.count == images.count else { return (0, 0) }
        return fractions(forBuffers: buffers, config: config)
    }

    /// Raw fixed-band row counts (top, bottom) across the frame sequence.
    static func detect(buffers: [PixelBuffer], config: Config = Config()) -> (topRows: Int, bottomRows: Int) {
        guard buffers.count >= 2 else { return (0, 0) }
        let height = buffers[0].height
        guard height > 0, buffers.allSatisfy({ $0.height == height }) else { return (0, 0) }

        var top = 0
        while top < height && rowFixed(top, buffers, config) { top += 1 }

        var bottom = 0
        while bottom < height && rowFixed(height - 1 - bottom, buffers, config) { bottom += 1 }

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

    /// True iff row `y` is identical (within threshold) across every consecutive frame pair.
    private static func rowFixed(_ y: Int, _ buffers: [PixelBuffer], _ config: Config) -> Bool {
        for i in 1..<buffers.count where rowDiff(buffers[i - 1], buffers[i], y) > config.rowMatchThreshold {
            return false
        }
        return true
    }

    /// Mean absolute difference between row `y` of two buffers (same width assumed).
    private static func rowDiff(_ a: PixelBuffer, _ b: PixelBuffer, _ y: Int) -> Float {
        let aRow = a.row(y), bRow = b.row(y)
        let n = min(aRow.count, bRow.count)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        let aBase = aRow.startIndex, bBase = bRow.startIndex
        for i in 0..<n { sum += abs(aRow[aBase + i] - bRow[bBase + i]) }
        return sum / Float(n)
    }
}
