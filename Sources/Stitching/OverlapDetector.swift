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
        /// Edge-feature NCC floor calibrated against real sparse chat & web captures.
        var acceptThreshold: Float = 0.60
        /// Stricter floor for micro-scrolls above `maxOverlapFraction` (`98.5%..<100%`).
        var highOverlapAcceptThreshold: Float = 0.80
        /// Full-height correlation floor for near-duplicate broadcast frames.
        var nearDuplicateThreshold: Float = 0.92
        var candidateCount: Int = 12
        var duplicateThreshold: Float = 0.995
        var minimumScoreMargin: Float = 0.002
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

        let maxOverlap = min(
            Int(Float(a.height) * config.maxOverlapFraction),
            Int(Float(b.height) * config.maxOverlapFraction)
        )
        // On tall full-resolution screenshots, avoid 16-row (< 1% height) coincidences by scaling
        // the floor to ~4% of height while keeping `config.minOverlap` exact on compact test images.
        let scaledFloor = a.height >= 450 ? max(config.minOverlap, a.height / 25) : config.minOverlap
        let effectiveMin = min(scaledFloor, maxOverlap)
        guard maxOverlap >= config.minOverlap, effectiveMin >= config.minOverlap else {
            return evidence("Too few rows for the configured overlap search")
        }
        let coarse = coarseCandidates(
            aMeans: a.rowMeans, bMeans: b.rowMeans,
            minOverlap: effectiveMin, maxOverlap: maxOverlap, keep: config.candidateCount
        )
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

    /// Scores primary candidates and merges high-confidence micro-scroll peaks in `(maxOverlap, height)`.
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

    /// Returns coarse overlap candidates for fine 2D NCC scoring.
    ///
    /// Damps ultra-short 1D correlation noise (`h / (h + 24)`) so coincidental blank+text spikes
    /// cannot hijack rank #1, and refines a `±3px` neighborhood around EVERY distinct NMS peak so
    /// 1–2px offsets between 1D row-means and 2D edge features never miss the true overlap.
    static func coarseCandidates(
        aMeans: [Float], bMeans: [Float], minOverlap: Int, maxOverlap: Int, keep: Int
    ) -> [Int] {
        guard minOverlap > 0, maxOverlap >= minOverlap, keep > 0,
              aMeans.count >= maxOverlap, bMeans.count >= maxOverlap else { return [] }
        var scored: [(overlap: Int, rankScore: Float)] = []
        scored.reserveCapacity(maxOverlap - minOverlap + 1)
        for h in minOverlap...maxOverlap {
            let raw = normalizedCorrelation(
                Array(aMeans[(aMeans.count - h)..<aMeans.count]),
                Array(bMeans[0..<h])
            )
            let weight = raw > 0 ? Float(h) / Float(h + 24) : 1
            scored.append((h, raw * weight))
        }
        scored.sort { $0.rankScore == $1.rankScore ? $0.overlap < $1.overlap : $0.rankScore > $1.rankScore }

        let peakLimit = max(2, min(keep, 8))
        let peakSeparation = max(12, (maxOverlap - minOverlap) / 32)
        var peakCenters: [Int] = []
        for cand in scored where peakCenters.count < peakLimit {
            if peakCenters.allSatisfy({ abs($0 - cand.overlap) > peakSeparation }) {
                peakCenters.append(cand.overlap)
            }
        }

        var chosen: [Int] = []
        var seen = Set<Int>()
        let refineRadius = 3
        for center in peakCenters {
            for h in (center - refineRadius)...(center + refineRadius)
            where h >= minOverlap && h <= maxOverlap && seen.insert(h).inserted {
                chosen.append(h)
            }
        }
        let wideSeparation = max(16, (maxOverlap - minOverlap) / max(keep, 1))
        for cand in scored where chosen.count < peakLimit * (refineRadius * 2 + 1) + keep {
            if peakCenters.allSatisfy({ abs($0 - cand.overlap) > wideSeparation }),
               seen.insert(cand.overlap).inserted {
                chosen.append(cand.overlap)
                peakCenters.append(cand.overlap)
            }
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
