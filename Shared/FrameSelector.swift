// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Coarse keyframe picker for the broadcast capture stream.
///
/// A 30–60 fps screen-recording stream is mostly redundant: while the finger is still every frame
/// is identical, and even during a scroll consecutive frames overlap almost entirely. This selector
/// thins that stream down to a sparse set of "content has advanced, still overlapping" keyframes,
/// leaving PRECISE overlap measurement and stitching to the existing `OverlapDetector` downstream.
///
/// It is deliberately signature-agnostic: it operates on a small downsampled grayscale signature
/// (`[Float]`, values 0...1) plus a timestamp. Extracting that signature from a `CMSampleBuffer`
/// lives in the extension (coupled to the image pipeline); this decision core stays pure so it can
/// be unit-tested on CI with synthetic scroll sequences, no device or image required.
///
/// Memory note: the selector keeps only ONE signature (the last kept frame) plus counters, so it
/// adds negligible footprint to the extension's ~50 MB budget. Full-resolution encoding of kept
/// frames happens outside this type.
enum FrameSelector {

    /// Tunables for the coarse pass, calibrated for live ReplayKit broadcast scrolling.
    struct Config {
        /// Below this mean-abs-diff vs the last kept frame (over the active middle band), the
        /// screen is treated as unchanged (finger still) and dropped as a duplicate.
        var duplicateThreshold: Float = 0.012

        /// At or above this active-band mean-abs-diff vs the last kept frame, content has changed
        /// enough to evaluate scroll displacement for a new keyframe.
        var changeThreshold: Float = 0.08

        /// Minimum wall-clock gap between two kept frames. Debounces bursts during fast scrolling
        /// so we don't emit dozens of near-adjacent keyframes.
        var minInterval: TimeInterval = 0.55

        /// Hard cap on kept frames for one recording. Bounds memory/stitch time even if the user
        /// scrolls a very long page or the thresholds misfire.
        var maxFrames: Int = 60

        /// Top and bottom row fractions excluded from signature comparison so status bars, Dynamic
        /// Island / recording pills, nav headers, and Home indicators neither trigger nor dilute diff.
        var topIgnoreFraction: Float = 0.125
        var bottomIgnoreFraction: Float = 0.125

        /// Minimum vertical scroll displacement (fraction of full frame height) required during
        /// active scrolling so kept keyframes land around ~45%–78% overlap instead of 90%+.
        var minScrollFraction: Float = 0.22

        /// Aligned mean-abs-diff below which a candidate shift `< minScrollFraction` counts as a
        /// genuine micro-scroll of the previous kept frame.
        var subScrollMatchThreshold: Float = 0.038

        /// After scrolling/pausing longer than this since the last keep, relax the displacement
        /// floor so a short final scroll at the very bottom of a page is still captured.
        var settleInterval: TimeInterval = 1.5
        var settledMinScrollFraction: Float = 0.06

        /// Row width of 2D signatures (`FrameEncoder.signatureSize`). Automatically falls back to
        /// 1-wide rows for short 1D test strips.
        var signatureWidth: Int = 64

        init() {}
    }

    /// Why a frame was kept or dropped. Distinct skip reasons make the coarse pass testable and
    /// debuggable; callers normally only care whether it is `.keep`.
    enum Decision: Equatable {
        case keep
        case skipDuplicate    // essentially identical to last kept frame (finger still)
        case skipMinorChange  // changed, but not enough to warrant a new keyframe yet
        case skipThrottled    // within `minInterval` of the last kept frame
        case skipCapped       // already hit `maxFrames`

        /// Convenience: did this decision retain the frame?
        var isKeep: Bool { self == .keep }
    }

    /// Immutable snapshot of what was last kept. `nil` before the first keep.
    struct State: Equatable {
        let signature: [Float]
        let timestamp: TimeInterval
        let keptCount: Int
        let lastStillTimestamp: TimeInterval?

        init(
            signature: [Float],
            timestamp: TimeInterval,
            keptCount: Int,
            lastStillTimestamp: TimeInterval? = nil
        ) {
            self.signature = signature
            self.timestamp = timestamp
            self.keptCount = keptCount
            self.lastStillTimestamp = lastStillTimestamp
        }
    }

    /// Pure decision for a single incoming frame.
    static func decide(
        signature: [Float],
        timestamp: TimeInterval,
        state: State?,
        config: Config = Config()
    ) -> Decision {
        guard timestamp.isFinite else { return .skipThrottled }
        // First frame of the recording is always a keyframe (nothing to compare against).
        guard let last = state else { return .keep }

        // Hard cap wins over everything: once full, drop the rest.
        if last.keptCount >= config.maxFrames { return .skipCapped }

        let sharedCount = min(signature.count, last.signature.count)
        let grid = activeGrid(count: sharedCount, config: config)
        let diff = sliceMeanAbsDiff(signature, last.signature, start: grid.startIndex, count: grid.sampleCount)

        // Finger still → identical active region → duplicate.
        if diff < config.duplicateThreshold { return .skipDuplicate }

        // Debounce bursts: even if content advanced, don't keep faster than minInterval.
        let elapsed = last.timestamp.isFinite ? (timestamp - last.timestamp) : 0
        if elapsed < config.minInterval { return .skipThrottled }

        // Changed, but only by jitter / sub-threshold contrast → wait for more advance.
        if diff < config.changeThreshold { return .skipMinorChange }

        // Measure dwell since the last still frame (if any) so pausing to read before starting a
        // slow scroll doesn't immediately relax `minScrollFraction`, while resting at page bottom
        // after a partial scroll still relaxes after `settleInterval`.
        let motionAnchor = max(last.timestamp, last.lastStillTimestamp ?? last.timestamp)
        let dwellElapsed = timestamp - motionAnchor
        let requiredScroll = dwellElapsed >= config.settleInterval
            ? config.settledMinScrollFraction
            : config.minScrollFraction
        if isSubThresholdScroll(
            current: signature,
            last: last.signature,
            grid: grid,
            zeroLagDiff: diff,
            minScrollFraction: requiredScroll,
            matchThreshold: config.subScrollMatchThreshold
        ) {
            return .skipMinorChange
        }

        return .keep
    }

    /// Mean absolute difference between two equal-length signatures (values 0...1).
    static func meanAbsDiff(_ a: [Float], _ b: [Float]) -> Float {
        sliceMeanAbsDiff(a, b, start: 0, count: min(a.count, b.count))
    }

    private struct ActiveGrid {
        let rowWidth: Int
        let totalRows: Int
        let startRow: Int
        let rowCount: Int
        var startIndex: Int { startRow * rowWidth }
        var sampleCount: Int { rowCount * rowWidth }
    }

    private static func activeGrid(count: Int, config: Config) -> ActiveGrid {
        guard count > 0 else { return ActiveGrid(rowWidth: 1, totalRows: 0, startRow: 0, rowCount: 0) }
        // Only treat exact square `signatureWidth × signatureWidth` buffers (e.g. 64×64 = 4096) as
        // 2D broadcast grids so arbitrary-length 1D test strips stay 1-wide.
        let isSquare2D = config.signatureWidth > 1
            && config.signatureWidth <= 1024
            && count == config.signatureWidth * config.signatureWidth
        let width = isSquare2D ? config.signatureWidth : 1
        let totalRows = count / width
        let topFrac = config.topIgnoreFraction.isFinite ? max(0, min(config.topIgnoreFraction, 0.45)) : 0
        let bottomFrac = config.bottomIgnoreFraction.isFinite ? max(0, min(config.bottomIgnoreFraction, 0.45)) : 0
        let topRows = Int((Float(totalRows) * topFrac).rounded(.down))
        let bottomRows = Int((Float(totalRows) * bottomFrac).rounded(.down))
        let activeRows = totalRows - topRows - bottomRows
        guard activeRows > 0 else {
            return ActiveGrid(rowWidth: width, totalRows: totalRows, startRow: 0, rowCount: totalRows)
        }
        return ActiveGrid(rowWidth: width, totalRows: totalRows, startRow: topRows, rowCount: activeRows)
    }

    private static func sliceMeanAbsDiff(_ a: [Float], _ b: [Float], start: Int, count: Int) -> Float {
        guard count > 0, start >= 0, start + count <= a.count, start + count <= b.count else { return 0 }
        var sum: Float = 0
        for i in start..<(start + count) { sum += abs(a[i] - b[i]) }
        return sum / Float(count)
    }

    private static func isSubThresholdScroll(
        current: [Float],
        last: [Float],
        grid: ActiveGrid,
        zeroLagDiff: Float,
        minScrollFraction: Float,
        matchThreshold: Float
    ) -> Bool {
        guard minScrollFraction.isFinite, matchThreshold.isFinite else { return false }
        let clampedFraction = max(0, min(minScrollFraction, 0.45))
        let maxShift = Int((Float(grid.totalRows) * clampedFraction).rounded(.down))
        guard maxShift >= 1, grid.rowCount > maxShift + 4 else { return false }
        let down = minShiftedDiff(movingUp: current, reference: last, grid: grid, maxShift: maxShift)
        let up = minShiftedDiff(movingUp: last, reference: current, grid: grid, maxShift: maxShift)
        let best = down.bestDiff <= up.bestDiff ? down : up
        // Strict `< boundaryDiff - 1e-4` ensures neither monotonic gradients nor blank-interior
        // edge-exit shifts (`bestDiff == 0` and `boundaryDiff == 0`) falsely report alignment.
        return best.bestDiff < matchThreshold
            && best.bestDiff < zeroLagDiff * 0.65
            && best.bestDiff + 1e-4 < best.boundaryDiff
    }

    /// Evaluates shifts `0.5 ... maxShift` (plus integer `maxShift + 1` as guard) where
    /// `movingUp[r]` aligns with `reference[r + shift]`.
    private static func minShiftedDiff(
        movingUp a: [Float],
        reference b: [Float],
        grid: ActiveGrid,
        maxShift: Int
    ) -> (bestDiff: Float, boundaryDiff: Float) {
        var best: Float = .greatestFiniteMagnitude
        let w = grid.rowWidth
        for s in 0...maxShift {
            if s >= 1 {
                let count = (grid.rowCount - s) * w
                let aBase = grid.startRow * w
                let bBase = (grid.startRow + s) * w
                var sum: Float = 0
                for i in 0..<count { sum += abs(a[aBase + i] - b[bBase + i]) }
                best = min(best, sum / Float(count))
            }
            if s < maxShift {
                let halfRows = grid.rowCount - s - 1
                if halfRows > 0 {
                    let count = halfRows * w
                    let aBase = grid.startRow * w
                    let bBase = (grid.startRow + s) * w
                    var sum: Float = 0
                    for i in 0..<count {
                        let blended = 0.5 * (b[bBase + i] + b[bBase + w + i])
                        sum += abs(a[aBase + i] - blended)
                    }
                    best = min(best, sum / Float(count))
                }
            }
        }
        let guardShift = maxShift + 1
        let guardCount = (grid.rowCount - guardShift) * w
        let aBase = grid.startRow * w
        let bBase = (grid.startRow + guardShift) * w
        var guardSum: Float = 0
        for i in 0..<guardCount { guardSum += abs(a[aBase + i] - b[bBase + i]) }
        return (best, guardSum / Float(guardCount))
    }
}

extension FrameSelector {

    /// Thin stateful driver over the pure `decide` core, for the single-threaded sample handler.
    ///
    /// The handler calls `consider(_:at:)` for every video frame; the engine tracks the last kept
    /// signature, keep count, and timestamp, advancing state only on a `.keep`. Reusing the pure
    /// core keeps all the branching logic unit-tested while this wrapper stays trivial.
    final class Engine {
        private let config: Config
        private(set) var state: State?

        init(config: Config = Config()) {
            self.config = config
        }

        /// Number of frames kept so far.
        var keptCount: Int { state?.keptCount ?? 0 }

        /// Evaluates one frame, advancing internal state on `.keep` and updating still-dwell time
        /// on `.skipDuplicate` so reading pauses don't prematurely relax `minScrollFraction`.
        func consider(_ signature: [Float], at timestamp: TimeInterval) -> Decision {
            guard timestamp.isFinite else { return .skipThrottled }
            let safeTime = state.map { max(timestamp, $0.timestamp) } ?? timestamp
            let decision = FrameSelector.decide(
                signature: signature,
                timestamp: safeTime,
                state: state,
                config: config
            )
            if decision.isKeep {
                state = State(
                    signature: signature,
                    timestamp: safeTime,
                    keptCount: (state?.keptCount ?? 0) + 1,
                    lastStillTimestamp: nil
                )
            } else if decision == .skipDuplicate, let current = state {
                state = State(
                    signature: current.signature,
                    timestamp: current.timestamp,
                    keptCount: current.keptCount,
                    lastStillTimestamp: safeTime
                )
            }
            return decision
        }
    }
}
