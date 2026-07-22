// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreGraphics
import Foundation

/// Recovers the top-to-bottom order of a small imported screenshot batch from overlap evidence.
/// Photos creation dates can describe import order rather than capture/scroll order.
enum ScreenshotSequenceOrderer {
    static let maximumAutomaticCount = 12

    static func order(
        images: [CGImage],
        topCropFraction: Float,
        bottomCropFraction: Float,
        detectorConfig: OverlapDetector.Config = .init()
    ) -> [Int]? {
        guard images.count >= 2, images.count <= maximumAutomaticCount else { return nil }
        let cropped = images.compactMap {
            try? ImageNormalizer.crop(
                $0,
                topFraction: topCropFraction,
                bottomFraction: bottomCropFraction
            )
        }
        guard cropped.count == images.count else { return nil }
        let buffers = cropped.compactMap { PixelBuffer.from($0) }
        guard buffers.count == images.count else { return nil }

        let scores = matchScores(buffers: buffers, config: detectorConfig)
        return bestCompletePath(scores: scores)
    }

    private static func matchScores(
        buffers: [PixelBuffer],
        config: OverlapDetector.Config
    ) -> [[Float?]] {
        var scores = Array(
            repeating: Array<Float?>(repeating: nil, count: buffers.count),
            count: buffers.count
        )
        for top in buffers.indices {
            for bottom in buffers.indices where top != bottom {
                let result = OverlapDetector.detect(
                    top: buffers[top],
                    bottom: buffers[bottom],
                    config: config
                )
                if result.status == .matched {
                    scores[top][bottom] = result.bestScore
                }
            }
        }
        return scores
    }

    /// Held-Karp dynamic programming. Batches are capped at 12, so worst case is bounded.
    private static func bestCompletePath(scores: [[Float?]]) -> [Int]? {
        let count = scores.count
        guard count >= 2, count < Int.bitWidth else { return nil }
        let stateCount = 1 << count
        struct Entry { let score: Float; let path: [Int] }
        var states = Array(
            repeating: Array<Entry?>(repeating: nil, count: count),
            count: stateCount
        )
        for index in 0..<count {
            states[1 << index][index] = Entry(score: 0, path: [index])
        }
        for mask in 1..<stateCount {
            for end in 0..<count {
                guard let entry = states[mask][end] else { continue }
                for next in 0..<count where mask & (1 << next) == 0 {
                    guard let edge = scores[end][next] else { continue }
                    let nextMask = mask | (1 << next)
                    let candidate = Entry(score: entry.score + edge, path: entry.path + [next])
                    if states[nextMask][next]?.score ?? -.infinity < candidate.score {
                        states[nextMask][next] = candidate
                    }
                }
            }
        }
        return states[stateCount - 1].compactMap { $0 }.max { $0.score < $1.score }?.path
    }
}
