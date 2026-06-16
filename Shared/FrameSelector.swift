// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Coarse keyframe picker for the broadcast capture stream (SPEC_v2 §3 — the one new v2 algorithm).
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

    /// Tunables for the coarse pass. Defaults are conservative first-version values (SPEC_v2 §3);
    /// real thresholds get tuned against live scrolling in Phase 3.
    struct Config {
        /// Below this mean-abs-diff vs the last kept frame, the screen is treated as unchanged
        /// (finger still / identical frame) and the frame is dropped as a duplicate.
        var duplicateThreshold: Float = 0.012

        /// At or above this mean-abs-diff vs the last kept frame, content has advanced enough to
        /// be worth a new keyframe. Frames between `duplicateThreshold` and this are minor jitter.
        var changeThreshold: Float = 0.05

        /// Minimum wall-clock gap between two kept frames. Debounces bursts during fast scrolling
        /// so we don't emit dozens of near-adjacent keyframes.
        var minInterval: TimeInterval = 0.3

        /// Hard cap on kept frames for one recording. Bounds memory/stitch time even if the user
        /// scrolls a very long page or the thresholds misfire.
        var maxFrames: Int = 60

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
    }

    /// Pure decision for a single incoming frame.
    ///
    /// - Parameters:
    ///   - signature: downsampled grayscale signature of the current frame (0...1). Must be the
    ///     same length as `state.signature` once a frame has been kept (full-screen frames are a
    ///     constant size during a recording, so this holds in practice).
    ///   - timestamp: monotonic time of the frame, in seconds.
    ///   - state: result of the previous keep, or `nil` if nothing has been kept yet.
    ///   - config: tunables.
    /// - Returns: the keep/skip `Decision`. State transitions are the caller's job (see `Engine`).
    static func decide(
        signature: [Float],
        timestamp: TimeInterval,
        state: State?,
        config: Config = Config()
    ) -> Decision {
        // First frame of the recording is always a keyframe (nothing to compare against).
        guard let last = state else { return .keep }

        // Hard cap wins over everything: once full, drop the rest.
        if last.keptCount >= config.maxFrames { return .skipCapped }

        let diff = meanAbsDiff(signature, last.signature)

        // Finger still → identical frame → duplicate.
        if diff < config.duplicateThreshold { return .skipDuplicate }

        // Debounce bursts: even if content advanced, don't keep faster than minInterval.
        if timestamp - last.timestamp < config.minInterval { return .skipThrottled }

        // Changed, but only by jitter / sub-threshold scroll → wait for more advance.
        if diff < config.changeThreshold { return .skipMinorChange }

        return .keep
    }

    /// Mean absolute difference between two equal-length signatures (values 0...1).
    ///
    /// Position-sensitive on purpose: a vertical scroll shifts content and raises the diff, while a
    /// still screen yields ~0. Mismatched lengths compare over the shared prefix (defensive; should
    /// not happen for constant-size full-screen frames) and an empty input yields 0.
    static func meanAbsDiff(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += abs(a[i] - b[i]) }
        return sum / Float(n)
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

        /// Evaluates one frame, advancing internal state when it is kept.
        /// - Returns: the `Decision`; the caller encodes/writes the frame only on `.keep`.
        func consider(_ signature: [Float], at timestamp: TimeInterval) -> Decision {
            let decision = FrameSelector.decide(
                signature: signature,
                timestamp: timestamp,
                state: state,
                config: config
            )
            if decision.isKeep {
                state = State(
                    signature: signature,
                    timestamp: timestamp,
                    keptCount: (state?.keptCount ?? 0) + 1
                )
            }
            return decision
        }
    }
}
