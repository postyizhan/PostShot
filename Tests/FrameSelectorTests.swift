// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import PostShot

/// Validates `FrameSelector` against synthetic 1D and 2D scroll sequences in signature space.
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
        // Same big advance, but only 0.1s later — inside the 0.55s min interval.
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

        // Over ~2s of scrolling with a 0.55s floor, we expect ~4–5 keyframes, plus the 1
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

    // MARK: - 2D 64x64 broadcast signature tests

    private func gridSignature(
        source: [Float],
        width: Int = 64,
        height: Int = 64,
        topBarRows: Int = 8,
        bottomBarRows: Int = 8,
        topValue: Float = 0.15,
        bottomValue: Float = 0.85,
        scrollRows: Int
    ) -> [Float] {
        var grid = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x
                if y < topBarRows {
                    grid[idx] = topValue
                } else if y >= height - bottomBarRows {
                    grid[idx] = bottomValue
                } else {
                    let srcIdx = ((y + scrollRows) * width + x) % source.count
                    grid[idx] = source[srcIdx]
                }
            }
        }
        return grid
    }

    func test2DIgnoresStatusAndHomeBarChangesWhenScrollAreaIsStill() {
        let source = tallStrip(height: 64 * 400, seed: 21)
        let first = gridSignature(source: source, topValue: 0.1, bottomValue: 0.9, scrollRows: 0)
        // Dramatic change inside top/bottom 8 fixed rows, zero movement in the middle 48 rows.
        let second = gridSignature(source: source, topValue: 0.95, bottomValue: 0.05, scrollRows: 0)
        let state = FrameSelector.State(signature: first, timestamp: 0, keptCount: 1)

        let decision = FrameSelector.decide(signature: second, timestamp: 2.0, state: state)
        XCTAssertEqual(decision, .skipDuplicate, "Fixed UI band changes must not trigger keyframes")
    }

    func test2DSuppressesMicroScrollUntilMeaningfulDisplacement() {
        let source = tallStrip(height: 64 * 400, seed: 22)
        let first = gridSignature(source: source, scrollRows: 0)
        let state = FrameSelector.State(signature: first, timestamp: 0, keptCount: 1)

        // 4/64 rows (~6.25% scroll, ~93.75% overlap) and 10/64 rows (~15.6% scroll) during active
        // scrolling (< settleInterval) must wait for further displacement.
        let micro4 = gridSignature(source: source, scrollRows: 4)
        let micro10 = gridSignature(source: source, scrollRows: 10)
        XCTAssertEqual(FrameSelector.decide(signature: micro4, timestamp: 0.6, state: state), .skipMinorChange)
        XCTAssertEqual(FrameSelector.decide(signature: micro10, timestamp: 1.1, state: state), .skipMinorChange)

        // 20/64 rows (~31% scroll, ~69% overlap) crosses minScrollFraction -> keep.
        let advanced = gridSignature(source: source, scrollRows: 20)
        XCTAssertEqual(FrameSelector.decide(signature: advanced, timestamp: 1.2, state: state), .keep)
    }

    func test2DSettledShortTailScrollIsKeptOnce() {
        let source = tallStrip(height: 64 * 400, seed: 23)
        let engine = FrameSelector.Engine()
        let start = gridSignature(source: source, scrollRows: 0)
        XCTAssertEqual(engine.consider(start, at: 0), .keep)

        // User reaches page bottom after scrolling 8/64 rows (12.5%) and rests finger.
        let tail = gridSignature(source: source, scrollRows: 8)
        XCTAssertEqual(engine.consider(tail, at: 0.7), .skipMinorChange, "During active scroll window, wait")
        XCTAssertEqual(engine.consider(tail, at: 1.6), .keep, "Once settled, retain tail frame at page bottom")
        XCTAssertEqual(engine.consider(tail, at: 2.3), .skipDuplicate, "Subsequent still frames are duplicates")
    }

    func test2DDoesNotDropLargeScrollAcrossBlankInterior() {
        // Regression: old content at top of active band exits while new content enters at bottom,
        // leaving a blank middle region where both shifted and guard-shift diffs equal 0.
        let width = 64, height = 64
        var first = [Float](repeating: 0.9, count: width * height)
        var second = [Float](repeating: 0.9, count: width * height)
        for y in 8..<13 {
            for x in 0..<width { first[y * width + x] = 0.1 }
        }
        for y in 51..<56 {
            for x in 0..<width { second[y * width + x] = 0.1 }
        }
        let state = FrameSelector.State(signature: first, timestamp: 0, keptCount: 1)
        XCTAssertEqual(FrameSelector.decide(signature: second, timestamp: 0.8, state: state), .keep,
                       "Large scroll across blank interior must not be mistaken for a micro-scroll")
    }

    func testReadingPauseDoesNotPrematurelyRelaxScrollFloor() {
        let source = tallStrip(height: 64 * 400, seed: 29)
        let engine = FrameSelector.Engine()
        let still = gridSignature(source: source, scrollRows: 0)
        XCTAssertEqual(engine.consider(still, at: 0), .keep)
        // User reads a still page for 2.5s (> settleInterval), then starts scrolling by only 5 rows.
        XCTAssertEqual(engine.consider(still, at: 2.5), .skipDuplicate)
        let tinyScroll = gridSignature(source: source, scrollRows: 5)
        XCTAssertEqual(engine.consider(tinyScroll, at: 2.6), .skipMinorChange,
                       "First micro-scroll right after a reading pause must still wait for full displacement")
    }

    func testNonFiniteAndBackwardTimestampsNeverPoisonEngine() {
        let strip = tallStrip(height: 600, seed: 31)
        let engine = FrameSelector.Engine()
        let first = window(strip, offset: 0, length: 256) // 256-sample 1D strip stays 1D
        let second = window(strip, offset: 120, length: 256)
        let third = window(strip, offset: 240, length: 256)

        XCTAssertEqual(engine.consider(first, at: 100.0), .keep)
        XCTAssertEqual(engine.consider(second, at: .nan), .skipThrottled)
        XCTAssertEqual(engine.consider(second, at: .infinity), .skipThrottled)
        XCTAssertEqual(engine.consider(second, at: 50.0), .skipThrottled, "Backward PTS jump is safely throttled")
        XCTAssertEqual(engine.consider(third, at: 101.0), .keep, "Engine recovers as soon as clock advances")
    }
}
