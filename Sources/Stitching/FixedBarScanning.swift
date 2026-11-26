// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Row-level scanning primitives for `FixedBarDetector`: chrome-outlier rejection, opaque +
/// frosted-glass fixed-row matching, and trim-to-structure retreat of each band's inner edge.
extension FixedBarDetector {

    /// Excludes frames whose top/bottom chrome bands differ drastically from the medoid frame
    /// (e.g. Control Center pulled down at recording stop, or the host app at recording start).
    static func filterChromeOutliers(_ buffers: [PixelBuffer], config: Config) -> [PixelBuffer] {
        guard buffers.count >= 3, config.chromeOutlierThreshold.isFinite else { return buffers }
        let height = buffers[0].height
        let band = max(1, min(height / 3, Int((Float(height) * config.maxBandFraction).rounded(.up))))
        var bestMedoid = 0
        var bestTotal: Float = .greatestFiniteMagnitude
        for i in buffers.indices {
            var sum: Float = 0
            for j in buffers.indices where i != j {
                sum += chromeBandDiff(buffers[i], buffers[j], bandRows: band)
            }
            if sum < bestTotal {
                bestTotal = sum
                bestMedoid = i
            }
        }
        let kept = buffers.filter {
            chromeBandDiff(buffers[bestMedoid], $0, bandRows: band) <= config.chromeOutlierThreshold
        }
        return kept.count >= 2 ? kept : buffers
    }

    private static func chromeBandDiff(_ a: PixelBuffer, _ b: PixelBuffer, bandRows: Int) -> Float {
        let w = a.width, h = a.height
        let count = bandRows * w
        guard count > 0, count <= a.rows.count, count <= b.rows.count else { return 0 }
        var sum: Float = 0
        for i in 0..<count { sum += abs(a.rows[i] - b.rows[i]) }
        let bottomStart = (h - bandRows) * w
        for i in bottomStart..<(bottomStart + count) { sum += abs(a.rows[i] - b.rows[i]) }
        return sum / Float(count * 2)
    }

    /// Length of the contiguous run of fixed rows starting at `start`, walking by `step` (±1).
    static func fixedRun(from start: Int, step: Int, _ buffers: [PixelBuffer], _ config: Config) -> Int {
        let height = buffers[0].height
        var y = start, run = 0
        while y >= 0, y < height, rowFixed(y, height: height, buffers, config) {
            run += 1
            y += step
        }
        return run
    }

    /// Rows of the portrait status bar / Dynamic Island band, or 0 when the skip doesn't apply.
    static func statusBandRows(aspectRatio: Float?, height: Int, config: Config) -> Int {
        guard let aspect = aspectRatio, aspect.isFinite, config.statusBandMinAspect.isFinite,
              aspect >= config.statusBandMinAspect, config.statusBandFraction.isFinite else { return 0 }
        let frac = max(0, min(config.statusBandFraction, config.maxBandFraction))
        return Int((Float(height) * frac).rounded(.down))
    }

    /// Retreats the top band's inner (lower) edge upward past flat, step-free rows.
    static func shrinkTop(_ top: Int, _ buffers: [PixelBuffer], _ config: Config) -> Int {
        var t = top
        while t > 0 {
            if isBarEdge(t - 1, inner: t, buffers, config) { break }
            t -= 1
        }
        return t
    }

    /// Retreats the bottom band's inner (upper) edge downward past flat, step-free rows.
    static func shrinkBottom(_ bottom: Int, _ buffers: [PixelBuffer], _ config: Config) -> Int {
        let height = buffers[0].height
        var b = bottom
        while b > 0 {
            let y = height - b
            if isBarEdge(y, inner: y - 1, buffers, config) { break }
            b -= 1
        }
        return b
    }

    /// True iff, in a majority of frames, row `y` has horizontal structure or a luminance step
    /// against its body-side neighbour `inner`.
    static func isBarEdge(_ y: Int, inner: Int, _ buffers: [PixelBuffer], _ config: Config) -> Bool {
        let majority = buffers.count / 2 + 1
        var structured = 0, stepped = 0
        for buffer in buffers {
            let row = buffer.row(y)
            guard !row.isEmpty else { continue }
            if let lo = row.min(), let hi = row.max(), hi - lo >= config.flatRangeThreshold {
                structured += 1
            }
            let neighbour = buffer.row(inner)
            if !neighbour.isEmpty, abs(rowMean(row) - rowMean(neighbour)) >= config.flatStepThreshold {
                stepped += 1
            }
        }
        return structured >= majority || stepped >= majority
    }

    private static func rowMean(_ row: ArraySlice<Float>) -> Float {
        guard !row.isEmpty else { return 0 }
        return row.reduce(0, +) / Float(row.count)
    }

    /// True iff row `y` matches across all frames (for 2–4 frames) or all-but-one frame (for >= 5).
    static func rowFixed(_ y: Int, height: Int, _ buffers: [PixelBuffer], _ config: Config) -> Bool {
        let count = buffers.count
        let requiredMatches = count >= 5 ? (count - 1) : count
        let trimColumns = isOuterSystemBand(y: y, height: height)
        let allowFrosted = isCandidateBarZone(y: y, height: height, config: config)
        for refIndex in [0, 1] where refIndex < count {
            var matches = 0
            for i in 0..<count {
                if i == refIndex || rowMatches(
                    buffers[refIndex], buffers[i], y,
                    trimColumns: trimColumns, allowFrosted: allowFrosted, config
                ) {
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

    private static func isCandidateBarZone(y: Int, height: Int, config: Config) -> Bool {
        guard config.maxBandFraction.isFinite else { return false }
        let band = max(1, Int((Float(height) * max(0, min(config.maxBandFraction, 0.45))).rounded(.up)))
        return y < band || y >= height - band
    }

    private static func rowMatches(
        _ a: PixelBuffer, _ b: PixelBuffer, _ y: Int,
        trimColumns: Bool, allowFrosted: Bool, _ config: Config
    ) -> Bool {
        let lumDiff = rowDiff(a, b, y, trimColumns: trimColumns, config)
        if lumDiff <= config.rowMatchThreshold { return true }
        guard allowFrosted, lumDiff <= config.frostedLuminanceThreshold else { return false }
        let edge = rowEdgeDiff(a, b, y, trimColumns: trimColumns, config)
        return edge.mean <= config.frostedMeanEdgeThreshold && edge.max <= config.frostedMaxEdgeThreshold
    }

    /// Mean absolute luminance difference on row `y`, optionally trimming narrow status outliers.
    private static func rowDiff(
        _ a: PixelBuffer, _ b: PixelBuffer, _ y: Int, trimColumns: Bool, _ config: Config
    ) -> Float {
        let aRow = a.row(y), bRow = b.row(y)
        let n = min(aRow.count, bRow.count)
        guard n > 0 else { return 0 }
        let aBase = aRow.startIndex, bBase = bRow.startIndex
        let trim = trimmedColumnCount(total: n, enabled: trimColumns, config: config)
        guard trim > 0 else {
            var sum: Float = 0
            for i in 0..<n { sum += abs(aRow[aBase + i] - bRow[bBase + i]) }
            return sum / Float(n)
        }
        var diffs = (0..<n).map { abs(aRow[aBase + $0] - bRow[bBase + $0]) }
        diffs.sort()
        let keep = n - trim
        return diffs.prefix(keep).reduce(0, +) / Float(keep)
    }

    /// Mean and max difference of horizontal adjacent-column deltas `|(a[x+1]-a[x]) - (b[x+1]-b[x])|`.
    /// Blurred tint behind frosted glass varies smoothly across `x` (tiny edge diff), whereas sharp
    /// scrolling text/cards create large localized edge jumps.
    private static func rowEdgeDiff(
        _ a: PixelBuffer, _ b: PixelBuffer, _ y: Int, trimColumns: Bool, _ config: Config
    ) -> (mean: Float, max: Float) {
        let aRow = a.row(y), bRow = b.row(y)
        let pairs = min(aRow.count, bRow.count) - 1
        guard pairs > 0 else { return (0, 0) }
        let aBase = aRow.startIndex, bBase = bRow.startIndex
        var diffs = [Float](repeating: 0, count: pairs)
        for i in 0..<pairs {
            let da = aRow[aBase + i + 1] - aRow[aBase + i]
            let db = bRow[bBase + i + 1] - bRow[bBase + i]
            diffs[i] = abs(da - db)
        }
        let trim = trimmedColumnCount(total: pairs, enabled: trimColumns, config: config)
        if trim > 0 { diffs.sort() }
        let slice = diffs.prefix(pairs - trim)
        guard let peak = slice.max() else { return (0, 0) }
        return (slice.reduce(0, +) / Float(slice.count), peak)
    }

    private static func trimmedColumnCount(total: Int, enabled: Bool, config: Config) -> Int {
        guard enabled, total >= 31, config.statusBandTrimColumnFraction.isFinite else { return 0 }
        let frac = max(0, min(config.statusBandTrimColumnFraction, 0.2))
        let count = Int((Float(total) * frac).rounded(.down))
        return (count > 0 && count < total) ? count : 0
    }
}
