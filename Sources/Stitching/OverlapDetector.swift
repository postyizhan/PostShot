// SPDX-License-Identifier: AGPL-3.0-or-later
import Accelerate
import CoreGraphics
import Foundation

enum MatchStatus: Equatable {
    case matched
    case duplicate
    case noOverlap
    case ambiguous
    case insufficientEvidence
    case invalidInput
}

struct OverlapCandidate: Equatable {
    let overlap: Int
    let score: Float
}

struct OverlapResult: Equatable {
    let status: MatchStatus
    let overlap: Int
    let bestScore: Float
    let secondBestScore: Float?
    let scoreMargin: Float?
    let candidates: [OverlapCandidate]
    let diagnostics: [String]
}

/// Conservative vertical-overlap matcher. Uncertain evidence is never represented by overlap zero.
enum OverlapDetector {
    struct Config {
        var minOverlap: Int = 16
        var maxOverlapFraction: Float = 0.985
        /// Edge-feature NCC is lower than raw-luminance NCC on sparse chat screenshots, because
        /// only bubble/text boundaries carry motion evidence. Calibrated against real 601x1306
        /// chat captures: valid adjacent pairs score 0.642...0.800 with margins >= 0.31, while
        /// unrelated simulator photos score <= 0.076. The distinct-competitor margin remains
        /// mandatory, so this is not a score-only acceptance rule.
        var acceptThreshold: Float = 0.60
        /// Stricter floor for micro-scrolls above `maxOverlapFraction` (`98.5%..<100%`), where
        /// nearly the entire viewport overlaps so genuine matches correlate strongly.
        var highOverlapAcceptThreshold: Float = 0.80
        /// Full-height correlation floor for near-duplicate broadcast frames whose minor H.264 or
        /// status-bar clock noise puts `fullScore` just under `duplicateThreshold` (`0.995`).
        var nearDuplicateThreshold: Float = 0.92
        var candidateCount: Int = 12
        var duplicateThreshold: Float = 0.995
        var minimumScoreMargin: Float = 0.002
        /// Minimum row separation between the winning overlap and a candidate that may count as a
        /// *competing* hypothesis for the ambiguity margin. Adjacent overlaps (h±1) are the same
        /// peak shifted one row; on smooth real content they score near-identically, so treating
        /// them as competitors would reject perfect matches. A genuine second hypothesis (e.g. a
        /// periodic/repeated-content peak) sits far from the winner. Effective separation also
        /// scales mildly with overlap length to clear the main lobe on tall images.
        var minCompetitorSeparation: Int = 16
    }

    static func detect(top: CGImage, bottom: CGImage, config: Config = Config()) -> OverlapResult {
        guard top.width == bottom.width, top.height == bottom.height,
              let a = PixelBuffer.from(top), let b = PixelBuffer.from(bottom) else {
            return invalid("Images must have equal positive canonical dimensions")
        }
        return detect(top: a, bottom: b, config: config)
    }

    static func detect(top a: PixelBuffer, bottom b: PixelBuffer, config: Config = Config()) -> OverlapResult {
        guard a.isStructurallyValid, b.isStructurallyValid, a.width == b.width,
              a.height == b.height else { return invalid("Malformed or unequal feature buffers") }
        guard isValidConfig(config) else { return invalid("Invalid detector configuration") }

        let fullScore = nccScore(aTail: a, bHead: b, overlap: a.height)
        if fullScore >= config.duplicateThreshold {
            return duplicateResult(height: a.height, score: fullScore)
        }

        let maxOverlap = min(Int(Float(a.height) * config.maxOverlapFraction), Int(Float(b.height) * config.maxOverlapFraction))
        guard maxOverlap >= config.minOverlap else {
            return evidence("Too few rows for the configured overlap search")
        }
        let coarse = coarseCandidates(aMeans: a.rowMeans, bMeans: b.rowMeans,
                                      minOverlap: config.minOverlap, maxOverlap: maxOverlap,
                                      keep: config.candidateCount)
        let ranked = buildRankedCandidates(coarse: coarse, maxOverlap: maxOverlap, top: a, bottom: b, config: config)
        return classify(ranked: ranked, fullScore: fullScore, fullHeight: a.height, config: config)
    }

    private static func isValidConfig(_ config: Config) -> Bool {
        config.minOverlap > 0 && config.candidateCount >= 2 &&
            config.maxOverlapFraction > 0 && config.maxOverlapFraction < 1 &&
            config.acceptThreshold >= -1 && config.acceptThreshold <= 1 &&
            config.highOverlapAcceptThreshold >= -1 && config.highOverlapAcceptThreshold <= 1 &&
            config.nearDuplicateThreshold >= -1 && config.nearDuplicateThreshold <= 1 &&
            config.duplicateThreshold >= -1 && config.duplicateThreshold <= 1 &&
            config.minimumScoreMargin.isFinite && config.minimumScoreMargin >= 0 &&
            config.minCompetitorSeparation >= 0
    }

    private static func duplicateResult(height: Int, score: Float) -> OverlapResult {
        OverlapResult(status: .duplicate, overlap: height, bestScore: score,
                      secondBestScore: nil, scoreMargin: nil,
                      candidates: [OverlapCandidate(overlap: height, score: score)], diagnostics: [])
    }

    /// Scores primary candidates and merges high-confidence micro-scroll peaks in `(maxOverlap, height)`
    /// so periodic lower peaks (`>= 0.60`) can never mask a genuine `98.5%..<100%` overlap, while
    /// weak fixed-wallpaper tails (`< highOverlapAcceptThreshold`) never enter competition.
    private static func buildRankedCandidates(
        coarse: [Int], maxOverlap: Int, top a: PixelBuffer, bottom b: PixelBuffer, config: Config
    ) -> [OverlapCandidate] {
        var seen = Set(coarse)
        var combined = coarse.map { OverlapCandidate(overlap: $0, score: nccScore(aTail: a, bHead: b, overlap: $0)) }
        let ceilingFloor = max(config.acceptThreshold, config.highOverlapAcceptThreshold)
        if maxOverlap + 1 < a.height {
            for h in (maxOverlap + 1)..<a.height where seen.insert(h).inserted {
                let score = nccScore(aTail: a, bHead: b, overlap: h)
                if score >= ceilingFloor {
                    combined.append(OverlapCandidate(overlap: h, score: score))
                }
            }
        }
        combined.sort { $0.score == $1.score ? $0.overlap < $1.overlap : $0.score > $1.score }
        return combined
    }

    private static func classify(
        ranked: [OverlapCandidate], fullScore: Float, fullHeight: Int, config: Config
    ) -> OverlapResult {
        let nearDupFloor = max(config.acceptThreshold, config.nearDuplicateThreshold)
        if fullScore >= nearDupFloor {
            let fullSep = max(config.minCompetitorSeparation, Int((Float(fullHeight) * 0.01).rounded(.up)))
            let distinct = ranked.first { abs(fullHeight - $0.overlap) > fullSep }
            if distinct == nil || fullScore - distinct!.score >= config.minimumScoreMargin {
                return duplicateResult(height: fullHeight, score: fullScore)
            }
        }
        guard let best = ranked.first, best.score.isFinite, best.score > -1 else {
            return evidence("NCC variance was insufficient")
        }
        let separation = max(config.minCompetitorSeparation, Int((Float(best.overlap) * 0.01).rounded(.up)))
        let competitor = ranked.dropFirst().first { abs($0.overlap - best.overlap) > separation }
        let margin = competitor.map { best.score - $0.score }
        guard best.score >= config.acceptThreshold else {
            return OverlapResult(status: .insufficientEvidence, overlap: 0, bestScore: best.score,
                                 secondBestScore: competitor?.score, scoreMargin: margin,
                                 candidates: ranked, diagnostics: ["Best score is below acceptance threshold"])
        }
        if let margin, margin < config.minimumScoreMargin {
            return OverlapResult(status: .ambiguous, overlap: best.overlap, bestScore: best.score,
                                 secondBestScore: competitor?.score, scoreMargin: margin,
                                 candidates: ranked, diagnostics: ["Competing overlap candidates are too close"])
        }
        return OverlapResult(status: .matched, overlap: best.overlap, bestScore: best.score,
                             secondBestScore: competitor?.score, scoreMargin: margin,
                             candidates: ranked, diagnostics: [])
    }

    /// Returns coarse overlap candidates for fine NCC scoring.
    ///
    /// Two goals must both be met, so a pure top-`keep`-by-score selection is not enough:
    /// 1. Refine the dominant peak to ±px — keep a tight neighborhood around the best coarse row.
    /// 2. Preserve DISTINCT competing peaks (e.g. periodic/repeated content) so genuine ambiguity
    ///    is still detectable. These are found by non-maximum suppression across the coarse curve.
    static func coarseCandidates(aMeans: [Float], bMeans: [Float], minOverlap: Int, maxOverlap: Int, keep: Int) -> [Int] {
        guard minOverlap > 0, maxOverlap >= minOverlap, keep > 0,
              aMeans.count >= maxOverlap, bMeans.count >= maxOverlap else { return [] }
        var scored: [(overlap: Int, score: Float)] = []
        for h in minOverlap...maxOverlap {
            let score = normalizedCorrelation(Array(aMeans[(aMeans.count - h)..<aMeans.count]), Array(bMeans[0..<h]))
            scored.append((h, score))
        }
        scored.sort { $0.score == $1.score ? $0.overlap < $1.overlap : $0.score > $1.score }
        guard let top = scored.first else { return [] }

        var chosen: [Int] = []
        var seen = Set<Int>()
        func add(_ h: Int) { if seen.insert(h).inserted { chosen.append(h) } }

        // (1) Dense neighborhood around the dominant peak for exact-row refinement.
        let refineRadius = 3
        for h in (top.overlap - refineRadius)...(top.overlap + refineRadius) where h >= minOverlap && h <= maxOverlap {
            add(h)
        }

        // (2) NMS: walk candidates best-first, adding peaks that are separated from all
        //     already-chosen peaks, so distinct hypotheses survive alongside the main lobe.
        let separation = max(8, (maxOverlap - minOverlap) / max(keep, 1))
        for cand in scored {
            if chosen.count >= keep { break }
            if chosen.allSatisfy({ abs($0 - cand.overlap) > separation }) { add(cand.overlap) }
        }
        return chosen
    }

    static func nccScore(aTail a: PixelBuffer, bHead b: PixelBuffer, overlap: Int) -> Float {
        guard a.isStructurallyValid, b.isStructurallyValid, a.width == b.width,
              overlap > 0, overlap <= a.height, overlap <= b.height,
              a.width <= Int.max / overlap else { return -1 }
        let count = overlap * a.width
        let aStart = (a.height - overlap) * a.width
        return normalizedCorrelation(Array(a.rows[aStart..<(aStart + count)]), Array(b.rows[0..<count]))
    }

    static func normalizedCorrelation(_ x: [Float], _ y: [Float]) -> Float {
        guard !x.isEmpty, x.count == y.count else { return -1 }
        let n = vDSP_Length(x.count)
        var meanX: Float = 0, meanY: Float = 0
        vDSP_meanv(x, 1, &meanX, n); vDSP_meanv(y, 1, &meanY, n)
        var cx = [Float](repeating: 0, count: x.count), cy = [Float](repeating: 0, count: y.count)
        var nx = -meanX, ny = -meanY
        vDSP_vsadd(x, 1, &nx, &cx, 1, n); vDSP_vsadd(y, 1, &ny, &cy, 1, n)
        var dot: Float = 0, normX: Float = 0, normY: Float = 0
        vDSP_dotpr(cx, 1, cy, 1, &dot, n); vDSP_svesq(cx, 1, &normX, n); vDSP_svesq(cy, 1, &normY, n)
        let denominator = (normX * normY).squareRoot()
        guard denominator > 1e-6 else { return -1 }
        return dot / denominator
    }

    private static func invalid(_ message: String) -> OverlapResult {
        OverlapResult(status: .invalidInput, overlap: 0, bestScore: -1, secondBestScore: nil,
                      scoreMargin: nil, candidates: [], diagnostics: [message])
    }

    private static func evidence(_ message: String) -> OverlapResult {
        OverlapResult(status: .insufficientEvidence, overlap: 0, bestScore: -1, secondBestScore: nil,
                      scoreMargin: nil, candidates: [], diagnostics: [message])
    }
}
