// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreGraphics
import Foundation

/// Detects fixed UI bars (status bar / nav bar / frosted-glass toolbar / bottom input or tab bar)
/// across a burst of screenshots so they can be auto-cropped before stitching.
///
/// Handles real-world iOS chrome across arbitrary apps:
/// 1. **Chrome-outlier filtering** — strips leading/trailing non-session frames (e.g. Control
///    Center pulled down to stop recording) before scanning so they cannot veto bar detection.
/// 2. **Status-band skip** — on portrait Dynamic Island screens, runs a second scan below the
///    status band (`6.5%`) so an animating island cannot hide a static app nav bar underneath.
/// 3. **Frosted-glass bars** — iOS `UIVisualEffectView` bars let blurred low-frequency tint drift
///    by `2%–7%` while keeping high-frequency horizontal glyph/border edges locked in place.
/// 4. **Trim-to-structure & inward margin** — retreats flat body whitespace back to real bar
///    structure, then adds a tiny `0.5%` inward margin to clear residual semi-transparent lines.
enum FixedBarDetector {

    struct Config {
        /// Per-row raw-luminance mean-abs-diff (0...1) below which two opaque rows match.
        var rowMatchThreshold: Float = 0.015
        /// Cap on automatically suggested band fraction so whitespace margins never eat body content.
        var maxBandFraction: Float = 0.18
        /// Fraction of highest-diff columns trimmed inside the outer `<= 10%` bands when `width >= 32`.
        var statusBandTrimColumnFraction: Float = 0.09
        /// Height fraction of the portrait status bar + Dynamic Island band skipped by the second scan.
        var statusBandFraction: Float = 0.065
        /// Minimum height/width ratio for the portrait status-band skip (full-screen iPhones ≈ 2.16).
        var statusBandMinAspect: Float = 2.0
        /// Max raw-luminance drift tolerated across a frosted-glass (`UIVisualEffectView`) bar row.
        var frostedLuminanceThreshold: Float = 0.075
        /// Max mean adjacent-column edge diff tolerated across a frosted-glass bar row.
        var frostedMeanEdgeThreshold: Float = 0.012
        /// Max single-column edge jump tolerated on frosted glass (rejects sharp scrolling text/UI).
        var frostedMaxEdgeThreshold: Float = 0.055
        /// Max chrome mean-abs-diff from the medoid frame before a frame is treated as an outlier
        /// scene (e.g. Control Center or app switcher) and excluded from bar detection.
        var chromeOutlierThreshold: Float = 0.085
        /// Row max−min luminance below which a row carries no horizontal structure.
        var flatRangeThreshold: Float = 0.02
        /// Adjacent row-mean luminance delta below which two rows show no vertical step.
        var flatStepThreshold: Float = 0.01
        /// Extra inward margin added to non-zero detected bars to strip semi-transparent hairlines.
        var edgeMarginFraction: Float = 0.005

        init() {}
    }

    /// Top fraction the screen-recording entry always crops (status bar + Dynamic Island), even
    /// when the page has no app nav bar for the detector to find.
    static let recordingStatusBandFloor: Float = 0.065

    /// Crop fractions (top, bottom), 0...maxBandFraction, for `StitchEngine.Options`.
    static func detectFractions(
        _ images: [CGImage], config: Config = Config(), minimumTopFraction: Float = 0
    ) -> (top: Float, bottom: Float) {
        let buffers = images.compactMap { luminanceBuffer(from: $0) }
        guard buffers.count == images.count, let first = images.first, first.width > 0 else { return (0, 0) }
        let aspect = Float(first.height) / Float(first.width)
        return fractions(
            forBuffers: buffers, aspectRatio: aspect, config: config, minimumTopFraction: minimumTopFraction
        )
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

    /// Fixed-band row counts (top, bottom) across the frame sequence.
    static func detect(
        buffers: [PixelBuffer], aspectRatio: Float? = nil, config: Config = Config()
    ) -> (topRows: Int, bottomRows: Int) {
        guard buffers.count >= 2 else { return (0, 0) }
        let width = buffers[0].width, height = buffers[0].height
        guard width > 0, height > 0,
              buffers.allSatisfy({ $0.isStructurallyValid && $0.width == width && $0.height == height }) else {
            return (0, 0)
        }

        let filtered = filterChromeOutliers(buffers, config: config)
        let active = filtered.count >= 2 ? filtered : buffers

        let strictTop = fixedRun(from: 0, step: 1, active, config)
        let strictBottom = fixedRun(from: height - 1, step: -1, active, config)
        if strictTop >= height { return (strictTop, strictBottom) }

        var top = strictTop
        let statusRows = statusBandRows(aspectRatio: aspectRatio, height: height, config: config)
        if statusRows > 0, statusRows < height {
            let run = fixedRun(from: statusRows, step: 1, active, config)
            if run > 0 { top = max(top, statusRows + run) }
        }
        return (shrinkTop(top, active, config), shrinkBottom(strictBottom, active, config))
    }

    /// Applies the inward edge margin, floor, cap, and all-fixed guard, returning fractions.
    static func fractions(
        forBuffers buffers: [PixelBuffer],
        aspectRatio: Float? = nil,
        config: Config = Config(),
        minimumTopFraction: Float = 0
    ) -> (top: Float, bottom: Float) {
        let (top, bottom) = detect(buffers: buffers, aspectRatio: aspectRatio, config: config)
        guard let height = buffers.first?.height, height > 0 else { return (0, 0) }
        guard top + bottom < height else { return (0, 0) }
        let margin = config.edgeMarginFraction.isFinite ? max(0, config.edgeMarginFraction) : 0
        let floor = minimumTopFraction.isFinite ? max(0, minimumTopFraction) : 0
        let rawTop = top > 0 ? (Float(top) / Float(height) + margin) : 0
        let rawBottom = bottom > 0 ? (Float(bottom) / Float(height) + margin) : 0
        let topFrac = min(max(rawTop, floor), config.maxBandFraction)
        let bottomFrac = min(rawBottom, config.maxBandFraction)
        return (topFrac, bottomFrac)
    }
}
