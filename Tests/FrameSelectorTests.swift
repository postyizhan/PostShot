// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import PostShot

/// Validates `FrameSelector` (SPEC_v2 §3) against synthetic scroll sequences in signature space.
///
/// The selector operates on downsampled grayscale signatures (`[Float]`), so these tests build
/// signatures directly — no CoreGraphics, fully deterministic, runs on CI without a device.
final class FrameSelectorTests: XCTestCase {

    // MARK: - Synthetic signature builder

    /// A tall deterministic 1-D "content strip": index → grayscale value 0...1. A scroll position
    /// `offset` reads a `length`-long window starting at `offset`, so two windows at nearby offsets
    /// overlap heavily (small diff) and far-apart offsets differ (large diff) — exactly the signal
    /// a vertical scroll produces.
    private func tallStrip(height: Int, seed: UInt64) -> [Float] {
        var state = seed &+ 0x9E3779B97F4A7C15
        func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float((state >> 40) & 0xFFFF) / Float(0xFFFF)
        }
        return (0..<height).map { _ in next() }
    }

    /// A signature window of `length` samples starting at `offset` into `strip` (clamped).
    private func window(_ strip: [Float], offset: Int, length: Int) -> [Float] {
        let start = min(max(offset, 0), max(strip.count - length, 0))
        return Array(strip[start..<(start + length)])
    }

    // MARK: - Pure decision tests

    func testFirstFrameIsAlwaysKept() {
        let sig = tallStrip(height: 64, seed: 1)
        let decision = FrameSelector.decide(signature: sig, timestamp: 0, state: nil)
        XCTAssertEqual(decision, .keep, "First frame has nothing to compare against → keep")
    }

    func testIdenticalFrameIsDuplicate() {
        let strip = tallStrip(height: 400, seed: 2)
        let sig = window(strip, offset: 0, length: 64)
        let state = FrameSelector.State(signature: sig, timestamp: 0, keptCount: 1)
        // Same signature, well past the throttle interval.
        let decision = FrameSelector.decide(signature: sig, timestamp: 5, state: state)
        XCTAssertEqual(decision, .skipDuplicate, "Identical frame (finger still) must be dropped")
    }

    func testAdvancedContentIsKept() {
        let strip = tallStrip(height: 400, seed: 3)
        let first = window(strip, offset: 0, length: 64)
        let scrolled = window(strip, offset: 60, length: 64) // big advance → large diff
        let state = FrameSelector.State(signature: first, timestamp: 0, keptCount: 1)
        let decision = FrameSelector.decide(signature: scrolled, timestamp: 1, state: state)
        XCTAssertEqual(decision, .keep, "A clear scroll advance must produce a new keyframe")
    }

    func testThrottleDropsRapidAdvance() {
        let strip = tallStrip(height: 400, seed: 4)
        let first = window(strip, offset: 0, length: 64)
        let scrolled = window(strip, offset: 60, length: 64)
        let state = FrameSelector.State(signature: first, timestamp: 1.0, keptCount: 1)
        // Same big advance, but only 0.1s later — inside the 0.3s min interval.
        let decision = FrameSelector.decide(signature: scrolled, timestamp: 1.1, state: state)
        XCTAssertEqual(decision, .skipThrottled, "Advances within minInterval must be throttled")
    }

    func testCapStopsKeeping() {
        let strip = tallStrip(height: 400, seed: 5)
        let first = window(strip, offset: 0, length: 64)
        let scrolled = window(strip, offset: 60, length: 64)
        var config = FrameSelector.Config()
        config.maxFrames = 10
        let state = FrameSelector.State(signature: first, timestamp: 0, keptCount: 10)
        let decision = FrameSelector.decide(signature: scrolled, timestamp: 5, state: state, config: config)
        XCTAssertEqual(decision, .skipCapped, "Once maxFrames reached, further frames are dropped")
    }

    func testMeanAbsDiffIdentityIsZero() {
        let sig = tallStrip(height: 64, seed: 6)
        XCTAssertEqual(FrameSelector.meanAbsDiff(sig, sig), 0, accuracy: 1e-6)
    }

    // MARK: - End-to-end engine over a synthetic scroll

    func testEngineThinsAStillThenScrollSequence() {
        // A realistic stream: 30 still frames (finger resting), then a steady scroll, sampled at
        // 60 fps. The engine should keep exactly one frame for the still period and a handful of
        // sparse keyframes for the scroll — never one-per-frame.
        let strip = tallStrip(height: 4000, seed: 42)
        let length = 64
        let engine = FrameSelector.Engine()

        var kept = 0
        var t: TimeInterval = 0
        let dt = 1.0 / 60.0

        // Phase A: 30 identical still frames at offset 0.
        let still = window(strip, offset: 0, length: length)
        for _ in 0..<30 {
            if engine.consider(still, at: t).isKeep { kept += 1 }
            t += dt
        }
        XCTAssertEqual(kept, 1, "A still screen must collapse to a single keyframe")

        // Phase B: scroll downward ~8 px per frame for 2 seconds (120 frames).
        var offset = 0
        for _ in 0..<120 {
            offset += 8
            let sig = window(strip, offset: offset, length: length)
            if engine.consider(sig, at: t).isKeep { kept += 1 }
            t += dt
        }

        // Over ~2s of scrolling with a 0.3s floor, we expect roughly 6–8 keyframes, plus the 1
        // still keyframe. Assert it's sparse (thinned) but progressing (not stuck at 1).
        XCTAssertGreaterThan(kept, 2, "Scrolling must produce multiple keyframes")
        XCTAssertLessThan(kept, 15, "Keyframes must be sparse, not one-per-frame")
        XCTAssertEqual(engine.keptCount, kept, "Engine count must match observed keeps")
    }

    func testEngineRespectsMaxFramesCap() {
        let strip = tallStrip(height: 100_000, seed: 7)
        let length = 64
        var config = FrameSelector.Config()
        config.maxFrames = 12
        config.minInterval = 0 // remove throttle so only the cap limits us
        let engine = FrameSelector.Engine(config: config)

        var kept = 0
        var offset = 0
        var t: TimeInterval = 0
        // Feed 500 strongly-advancing frames; cap must hold keeps at maxFrames.
        for _ in 0..<500 {
            offset += 40
            let sig = window(strip, offset: offset, length: length)
            if engine.consider(sig, at: t).isKeep { kept += 1 }
            t += 0.5
        }
        XCTAssertEqual(kept, config.maxFrames, "Engine must never keep more than maxFrames")
    }
}
