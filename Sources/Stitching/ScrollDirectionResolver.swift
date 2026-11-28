// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreGraphics
import Foundation

/// Bidirectional pool-index range for bridging gaps in forward or reversed recordings.
struct PoolSpan {
    let start: Int
    let count: Int
    let step: Int

    static func between(_ fromPool: Int, _ toPool: Int) -> PoolSpan? {
        if toPool - fromPool >= 2 { return PoolSpan(start: fromPool + 1, count: toPool - fromPool - 1, step: 1) }
        if fromPool - toPool >= 2 { return PoolSpan(start: fromPool - 1, count: fromPool - toPool - 1, step: -1) }
        return nil
    }

    var midOffset: Int { count / 2 }
    var offsets: Range<Int> { 0..<max(0, count) }
    func poolIndex(at offset: Int) -> Int { start + offset * step }
    var leftHalf: PoolSpan? { midOffset > 0 ? PoolSpan(start: start, count: midOffset, step: step) : nil }
    var rightHalf: PoolSpan? {
        let rem = count - midOffset - 1
        return rem > 0 ? PoolSpan(start: poolIndex(at: midOffset + 1), count: rem, step: step) : nil
    }

    func prefix(upTo offset: Int) -> PoolSpan? {
        let clamped = min(offset, count)
        return clamped > 0 ? PoolSpan(start: start, count: clamped, step: step) : nil
    }

    func suffix(after offset: Int) -> PoolSpan? {
        let rem = count - offset - 1
        return rem > 0 ? PoolSpan(start: poolIndex(at: offset + 1), count: rem, step: step) : nil
    }
}

struct DirectionAnalysis {
    let direction: ScrollDirection
    let isHeavyZigZag: Bool
    let firstConflictPair: (top: Int, bottom: Int)?
    let firstConflictResult: OverlapResult?
}

enum BacktrackOutcome<Connection> {
    case none
    case excessiveBacktrack(failingIndex: Int)
    case reconnected(target: Int, connection: Connection, skippedCount: Int)
    case trailingBacktrack(skippedCount: Int)
}

/// Pure geometric analyzers for scroll direction voting, heavy zig-zag rejection, and minor backtrack recovery.
enum ScrollDirectionResolver {
    private static let maxBacktrackFrames = 6

    private struct StepVote {
        let vote: Int
        let shift: Int
        let isDuplicate: Bool
        let fwdResult: OverlapResult?
        let revResult: OverlapResult?
    }

    private struct VoteTally {
        var forwardMatches = 0, reverseMatches = 0
        var forwardScoreSum: Float = 0, reverseScoreSum: Float = 0

        mutating func record(vote: Int, score: Float) {
            if vote > 0 { forwardMatches += 1; forwardScoreSum += score }
            else if vote < 0 { reverseMatches += 1; reverseScoreSum += score }
        }
    }

    static func analyze(
        buffers: [PixelBuffer?], poolIndices: [Int]?, options: StitchEngine.Options, canonicalSize: PixelSize
    ) -> DirectionAnalysis {
        guard buffers.count >= 2 else {
            return DirectionAnalysis(direction: .topToBottom, isHeavyZigZag: false, firstConflictPair: nil, firstConflictResult: nil)
        }
        var tally = VoteTally()
        var steps: [StepVote] = []
        steps.reserveCapacity(buffers.count - 1)
        for i in 0..<(buffers.count - 1) {
            let eval = evaluatePair(buffers[i], buffers[i + 1], config: options.detectorConfig)
            tally.record(vote: eval.vote, score: eval.score)
            steps.append(StepVote(vote: eval.vote, shift: eval.shift, isDuplicate: eval.isDuplicate, fwdResult: eval.fwd, revResult: eval.rev))
        }
        if tally.forwardMatches + tally.reverseMatches < 2 || tally.forwardMatches == tally.reverseMatches {
            addSkipOneVotes(buffers: buffers, steps: steps, config: options.detectorConfig, tally: &tally)
        }
        if tally.forwardMatches == 0, tally.reverseMatches == 0,
           options.backfill != nil, let pIndices = poolIndices, pIndices.count >= 2 {
            probeSparsePool(poolIndices: pIndices, options: options, canonicalSize: canonicalSize, tally: &tally)
        }
        let isReverse = tally.reverseMatches > tally.forwardMatches || (
            tally.reverseMatches == tally.forwardMatches &&
            tally.reverseMatches > 0 && tally.reverseScoreSum > tally.forwardScoreSum + 0.02
        )
        let direction: ScrollDirection = isReverse ? .bottomToTop : .topToBottom
        let frameHeight = buffers.compactMap { $0?.height }.first ?? 0
        let zigZag = detectHeavyZigZag(steps: steps, direction: direction, frameHeight: frameHeight)
        return DirectionAnalysis(
            direction: direction, isHeavyZigZag: zigZag.isHeavy,
            firstConflictPair: zigZag.pair, firstConflictResult: zigZag.result
        )
    }

    static func detectMinorBacktrackSkip<Connection>(
        anchor: Int, failingAt index: Int, buffers: [PixelBuffer?],
        config: OverlapDetector.Config, tryConnect: (Int, Int) -> Connection?
    ) -> BacktrackOutcome<Connection> {
        guard anchor >= 0, index > anchor, index < buffers.count,
              let anchorBuf = buffers[anchor], anchorBuf.height > 0 else { return .none }
        let frameHeight = anchorBuf.height
        var prev = anchor, relY = 0, sawReverse = false
        let upper = min(buffers.count, index + maxBacktrackFrames)

        for j in index..<upper {
            guard let prevBuf = buffers[prev], let curBuf = buffers[j] else { break }
            let rev = OverlapDetector.detect(top: curBuf, bottom: prevBuf, config: config)
            let fwd = OverlapDetector.detect(top: prevBuf, bottom: curBuf, config: config)
            if rev.status == .duplicate {
                if relY < 0 { sawReverse = true }
            } else if rev.status == .matched && (fwd.status != .matched || rev.bestScore >= fwd.bestScore) {
                relY -= max(0, curBuf.height - rev.overlap); sawReverse = true
            } else if fwd.status == .matched && relY < 0 {
                relY += max(0, prevBuf.height - fwd.overlap)
            } else {
                break
            }
            prev = j
            if relY < -frameHeight { return .excessiveBacktrack(failingIndex: j) }
            if sawReverse, j + 1 < buffers.count, let conn = tryConnect(anchor, j + 1) {
                return .reconnected(target: j + 1, connection: conn, skippedCount: (j + 1) - index)
            }
            if sawReverse, j == buffers.count - 1, relY < 0, relY >= -frameHeight {
                return .trailingBacktrack(skippedCount: buffers.count - index)
            }
        }
        return .none
    }

    static func isReversePair(_ a: PixelBuffer?, _ b: PixelBuffer?, config: OverlapDetector.Config) -> Bool {
        guard let a, let b else { return false }
        return OverlapDetector.detect(top: b, bottom: a, config: config).status == .matched
    }

    private static func evaluatePair(
        _ a: PixelBuffer?, _ b: PixelBuffer?, config: OverlapDetector.Config
    ) -> (vote: Int, score: Float, shift: Int, isDuplicate: Bool, fwd: OverlapResult?, rev: OverlapResult?) {
        guard let a, let b else { return (0, 0, 0, false, nil, nil) }
        let fwd = OverlapDetector.detect(top: a, bottom: b, config: config)
        let rev = OverlapDetector.detect(top: b, bottom: a, config: config)
        if fwd.status == .duplicate { return (0, 0, 0, true, fwd, rev) }
        let fwdOk = fwd.status == .matched, revOk = rev.status == .matched
        if fwdOk && !revOk { return (1, fwd.bestScore, max(0, a.height - fwd.overlap), false, fwd, rev) }
        if revOk && !fwdOk { return (-1, rev.bestScore, max(0, a.height - rev.overlap), false, fwd, rev) }
        if fwdOk && revOk {
            return rev.bestScore > fwd.bestScore + 1e-3
                ? (-1, rev.bestScore, max(0, a.height - rev.overlap), false, fwd, rev)
                : (1, fwd.bestScore, max(0, a.height - fwd.overlap), false, fwd, rev)
        }
        return (0, 0, 0, false, fwd, rev)
    }

    private static func addSkipOneVotes(
        buffers: [PixelBuffer?], steps: [StepVote], config: OverlapDetector.Config, tally: inout VoteTally
    ) {
        guard buffers.count >= 3 else { return }
        for i in 0..<(buffers.count - 2) where steps[i].vote == 0 && !steps[i].isDuplicate {
            let eval = evaluatePair(buffers[i], buffers[i + 2], config: config)
            tally.record(vote: eval.vote, score: eval.score)
        }
    }

    private static func probeSparsePool(
        poolIndices: [Int], options: StitchEngine.Options, canonicalSize: PixelSize, tally: inout VoteTally
    ) {
        guard let first = poolIndices.first, let last = poolIndices.last else { return }
        let pairCount = abs(last - first)
        guard pairCount > 0 else { return }
        let poolStep = last >= first ? 1 : -1
        let sampleCount = min(6, pairCount)
        for k in 0..<sampleCount {
            let offset = sampleCount == 1 ? 0 : (k * (pairCount - 1)) / (sampleCount - 1)
            let p = first + offset * poolStep
            let b0 = loadPoolBuffer(at: p, options: options, canonicalSize: canonicalSize)
            let b1 = loadPoolBuffer(at: p + poolStep, options: options, canonicalSize: canonicalSize)
            let eval = evaluatePair(b0, b1, config: options.detectorConfig)
            tally.record(vote: eval.vote, score: eval.score)
        }
    }

    private static func loadPoolBuffer(
        at poolIndex: Int, options: StitchEngine.Options, canonicalSize: PixelSize
    ) -> PixelBuffer? {
        guard let raw = options.backfill?.loadFrame(poolIndex),
              let cropped = try? ImageNormalizer.crop(
                  raw, topFraction: options.topCropFraction, bottomFraction: options.bottomCropFraction
              ),
              cropped.width == canonicalSize.width, cropped.height == canonicalSize.height else { return nil }
        return PixelBuffer.from(cropped)
    }

    private static func detectHeavyZigZag(
        steps: [StepVote], direction: ScrollDirection, frameHeight: Int
    ) -> (isHeavy: Bool, pair: (top: Int, bottom: Int)?, result: OverlapResult?) {
        let majorDir = (direction == .topToBottom) ? 1 : -1
        let minorDir = -majorDir
        var minorTravel = 0, minorBurstCount = 0, prevNonZeroVote = 0, triggerIdx: Int?
        for (i, step) in steps.enumerated() {
            if step.vote == minorDir {
                if prevNonZeroVote != minorDir { minorBurstCount += 1 }
                minorTravel += step.shift
                if triggerIdx == nil, frameHeight > 0, minorTravel > frameHeight || minorBurstCount > 2 { triggerIdx = i }
            }
            if step.vote != 0 { prevNonZeroVote = step.vote }
        }
        guard let idx = triggerIdx else { return (false, nil, nil) }
        let result = majorDir == 1 ? steps[idx].fwdResult : steps[idx].revResult
        return (true, (idx, idx + 1), result)
    }
}
