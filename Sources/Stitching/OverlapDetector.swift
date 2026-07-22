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
        var maxOverlapFraction: Float = 0.95
        var acceptThreshold: Float = 0.85
        var candidateCount: Int = 12
        var duplicateThreshold: Float = 0.995
        var minimumScoreMargin: Float = 0.002
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
        guard config.minOverlap > 0, config.candidateCount >= 2,
              config.maxOverlapFraction > 0, config.maxOverlapFraction < 1,
              config.acceptThreshold >= -1, config.acceptThreshold <= 1,
              config.duplicateThreshold >= -1, config.duplicateThreshold <= 1,
              config.minimumScoreMargin >= 0 else { return invalid("Invalid detector configuration") }

        let fullScore = nccScore(aTail: a, bHead: b, overlap: a.height)
        if fullScore >= config.duplicateThreshold {
            return OverlapResult(status: .duplicate, overlap: a.height, bestScore: fullScore,
                                 secondBestScore: nil, scoreMargin: nil,
                                 candidates: [OverlapCandidate(overlap: a.height, score: fullScore)], diagnostics: [])
        }

        let maxOverlap = min(Int(Float(a.height) * config.maxOverlapFraction), Int(Float(b.height) * config.maxOverlapFraction))
        guard maxOverlap >= config.minOverlap else {
            return evidence("Too few rows for the configured overlap search")
        }
        let coarse = coarseCandidates(aMeans: a.rowMeans, bMeans: b.rowMeans,
                                      minOverlap: config.minOverlap, maxOverlap: maxOverlap,
                                      keep: config.candidateCount)
        var ranked = coarse.map { overlap in
            OverlapCandidate(overlap: overlap, score: nccScore(aTail: a, bHead: b, overlap: overlap))
        }
        ranked.sort {
            if $0.score == $1.score { return $0.overlap < $1.overlap }
            return $0.score > $1.score
        }
        guard let best = ranked.first, best.score.isFinite, best.score > -1 else {
            return evidence("NCC variance was insufficient")
        }
        let second = ranked.dropFirst().first
        let margin = second.map { best.score - $0.score }
        guard best.score >= config.acceptThreshold else {
            return OverlapResult(status: .insufficientEvidence, overlap: 0, bestScore: best.score,
                                 secondBestScore: second?.score, scoreMargin: margin,
                                 candidates: ranked, diagnostics: ["Best score is below acceptance threshold"])
        }
        if let margin, margin < config.minimumScoreMargin {
            return OverlapResult(status: .ambiguous, overlap: best.overlap, bestScore: best.score,
                                 secondBestScore: second?.score, scoreMargin: margin,
                                 candidates: ranked, diagnostics: ["Competing overlap candidates are too close"])
        }
        return OverlapResult(status: .matched, overlap: best.overlap, bestScore: best.score,
                             secondBestScore: second?.score, scoreMargin: margin,
                             candidates: ranked, diagnostics: [])
    }

    static func coarseCandidates(aMeans: [Float], bMeans: [Float], minOverlap: Int, maxOverlap: Int, keep: Int) -> [Int] {
        guard minOverlap > 0, maxOverlap >= minOverlap, keep > 0,
              aMeans.count >= maxOverlap, bMeans.count >= maxOverlap else { return [] }
        var scored: [(Int, Float)] = []
        for h in minOverlap...maxOverlap {
            let score = normalizedCorrelation(Array(aMeans[(aMeans.count - h)..<aMeans.count]), Array(bMeans[0..<h]))
            scored.append((h, score))
        }
        scored.sort { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        return scored.prefix(keep).map(\.0)
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
