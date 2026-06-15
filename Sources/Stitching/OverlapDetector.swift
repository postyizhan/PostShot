// SPDX-License-Identifier: AGPL-3.0-or-later
import Accelerate
import CoreGraphics
import Foundation

/// Finds the best vertical overlap between two vertically-adjacent screenshots.
///
/// Pure, testable. Input images are assumed already normalized to the same width
/// (callers use `normalizedWidth` / scaling before invoking). Output is the number
/// of overlapping pixel rows (0 == no overlap, append directly). See SPEC §2.1.
enum OverlapDetector {

    struct Config {
        /// Minimum overlap to consider, in rows. Below this we treat as no overlap.
        var minOverlap: Int = 16
        /// Fraction of the shorter image height to cap the search. Avoids absurd overlaps.
        var maxOverlapFraction: Float = 0.95
        /// NCC score below this → declare no overlap and append.
        var acceptThreshold: Float = 0.85
        /// Number of coarse-search candidates carried into the fine NCC stage.
        var candidateCount: Int = 12
        /// NCC above this → images considered near-duplicate (caller may dedup).
        var duplicateThreshold: Float = 0.995
    }

    struct Result {
        /// Overlapping row count between A (top) and B (bottom). 0 == append directly.
        let overlap: Int
        /// NCC score of the chosen overlap, 0...1.
        let score: Float
        /// True when the two images are near-identical (SPEC §2.1 step 5).
        let isDuplicate: Bool
    }

    /// Detects overlap directly from two `CGImage`s.
    static func detect(top: CGImage, bottom: CGImage, config: Config = Config()) -> Result {
        guard let a = PixelBuffer.from(top), let b = PixelBuffer.from(bottom) else {
            return Result(overlap: 0, score: 0, isDuplicate: false)
        }
        return detect(top: a, bottom: b, config: config)
    }

    /// Detects overlap between two prepared `PixelBuffer`s.
    static func detect(top a: PixelBuffer, bottom b: PixelBuffer, config: Config = Config()) -> Result {
        let maxByA = Int(Float(a.height) * config.maxOverlapFraction)
        let maxByB = Int(Float(b.height) * config.maxOverlapFraction)
        let maxOverlap = min(maxByA, maxByB)
        guard maxOverlap >= config.minOverlap else {
            return Result(overlap: 0, score: 0, isDuplicate: false)
        }

        // Stage 1: 1D coarse search over row means to find candidate overlaps.
        let candidates = coarseCandidates(
            aMeans: a.rowMeans,
            bMeans: b.rowMeans,
            minOverlap: config.minOverlap,
            maxOverlap: maxOverlap,
            keep: config.candidateCount
        )

        // Stage 2: fine NCC on full row signatures for each candidate.
        var bestOverlap = 0
        var bestScore: Float = -1
        for h in candidates {
            let score = nccScore(aTail: a, bHead: b, overlap: h)
            if score > bestScore {
                bestScore = score
                bestOverlap = h
            }
        }

        guard bestScore >= config.acceptThreshold else {
            return Result(overlap: 0, score: max(0, bestScore), isDuplicate: false)
        }

        let isDuplicate = bestScore >= config.duplicateThreshold
            && bestOverlap >= min(a.height, b.height) - 2
        return Result(overlap: bestOverlap, score: bestScore, isDuplicate: isDuplicate)
    }

    // MARK: - Stage 1: coarse 1D cross-correlation over row means

    /// Returns the top `keep` candidate overlap heights ranked by 1D NCC of row means.
    static func coarseCandidates(
        aMeans: [Float],
        bMeans: [Float],
        minOverlap: Int,
        maxOverlap: Int,
        keep: Int
    ) -> [Int] {
        var scored: [(h: Int, s: Float)] = []
        scored.reserveCapacity(maxOverlap - minOverlap + 1)
        let aCount = aMeans.count
        for h in minOverlap...maxOverlap {
            // A's last h means vs B's first h means.
            let aStart = aCount - h
            let aSlice = Array(aMeans[aStart..<aCount])
            let bSlice = Array(bMeans[0..<h])
            let s = normalizedCorrelation(aSlice, bSlice)
            scored.append((h, s))
        }
        scored.sort { $0.s > $1.s }
        return scored.prefix(keep).map { $0.h }
    }

    // MARK: - Stage 2: fine NCC over full row signatures

    /// Normalized cross-correlation between A's last `overlap` rows and B's first `overlap` rows.
    static func nccScore(aTail a: PixelBuffer, bHead b: PixelBuffer, overlap: Int) -> Float {
        guard overlap > 0, overlap <= a.height, overlap <= b.height else { return -1 }
        let width = a.width
        let n = overlap * width
        let aStartRow = a.height - overlap

        var aVec = [Float](repeating: 0, count: n)
        var bVec = [Float](repeating: 0, count: n)
        a.rows.withUnsafeBufferPointer { ap in
            b.rows.withUnsafeBufferPointer { bp in
                let aSrc = ap.baseAddress! + aStartRow * width
                memcpy(&aVec, aSrc, n * MemoryLayout<Float>.stride)
                memcpy(&bVec, bp.baseAddress!, n * MemoryLayout<Float>.stride)
            }
        }
        return normalizedCorrelation(aVec, bVec)
    }

    // MARK: - Shared NCC primitive (vDSP)

    /// Normalized cross-correlation of two equal-length vectors, range roughly -1...1.
    /// Mean-centered and magnitude-normalized → robust to brightness drift (SPEC §2.1 step 3).
    static func normalizedCorrelation(_ x: [Float], _ y: [Float]) -> Float {
        let n = vDSP_Length(min(x.count, y.count))
        guard n > 0 else { return -1 }

        var meanX: Float = 0
        var meanY: Float = 0
        vDSP_meanv(x, 1, &meanX, n)
        vDSP_meanv(y, 1, &meanY, n)

        var cx = [Float](repeating: 0, count: Int(n))
        var cy = [Float](repeating: 0, count: Int(n))
        var negMeanX = -meanX
        var negMeanY = -meanY
        vDSP_vsadd(x, 1, &negMeanX, &cx, 1, n)
        vDSP_vsadd(y, 1, &negMeanY, &cy, 1, n)

        var dot: Float = 0
        var normX: Float = 0
        var normY: Float = 0
        vDSP_dotpr(cx, 1, cy, 1, &dot, n)
        vDSP_svesq(cx, 1, &normX, n)
        vDSP_svesq(cy, 1, &normY, n)

        let denom = (normX * normY).squareRoot()
        guard denom > 1e-6 else { return 0 }
        return dot / denom
    }
}
