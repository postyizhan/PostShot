// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreGraphics
import Foundation

/// Resolves a sequence of cropped frames into composable segments, automatically backfilling gaps
/// from the dense recording pool and skipping isolated outlier frames (such as Control Center).
enum StitchGraphResolver {

    struct ResolvedChain {
        let segments: [ImageCompositor.Segment]
        let skippedIndices: [Int]
        let backfilledCount: Int
    }

    private struct Node {
        let image: CGImage
        let buffer: PixelBuffer?
        let poolIndex: Int?
    }

    private enum LinkOutcome {
        case connected(segments: [ImageCompositor.Segment], backfilled: Int)
        case failed(OverlapResult)
    }

    static func resolve(
        images: [CGImage],
        options: StitchEngine.Options,
        canonicalSize: PixelSize,
        progress: StitchEngine.ProgressHandler
    ) -> Result<ResolvedChain, StitchEngine.StitchError> {
        let poolIndices = (options.backfill?.poolIndices.count == images.count)
            ? options.backfill?.poolIndices : nil
        let nodes = images.enumerated().map { idx, img in
            Node(image: img, buffer: PixelBuffer.from(img), poolIndex: poolIndices?[idx])
        }
        if nodes.count == 1 {
            return .success(ResolvedChain(
                segments: [ImageCompositor.Segment(image: nodes[0].image, overlap: 0)],
                skippedIndices: [], backfilledCount: 0
            ))
        }

        let maxSkip = max(0, options.maxSkippedOutliers)
        switch findInitialConnection(nodes: nodes, maxSkip: maxSkip, options: options, canonicalSize: canonicalSize) {
        case .failure(let error):
            return .failure(error)
        case .success(let start):
            return walkChain(
                nodes: nodes, initial: start, maxSkip: maxSkip,
                options: options, canonicalSize: canonicalSize, progress: progress
            )
        }
    }

    private struct InitialStep {
        let anchor: Int
        let next: Int
        let segments: [ImageCompositor.Segment]
        let skipped: [Int]
        let backfilled: Int
    }

    private static func findInitialConnection(
        nodes: [Node], maxSkip: Int, options: StitchEngine.Options, canonicalSize: PixelSize
    ) -> Result<InitialStep, StitchEngine.StitchError> {
        let count = nodes.count
        var firstFailure: OverlapResult?
        let maxStart = min(maxSkip, count - 2)
        for start in 0...maxStart {
            let maxTarget = min(count - 1, start + 1 + maxSkip)
            for target in (start + 1)...maxTarget {
                let outcome = connect(
                    from: nodes[start], to: nodes[target], options: options, canonicalSize: canonicalSize
                )
                if start == 0, target == 1, case .failed(let res) = outcome {
                    firstFailure = res
                }
                if case .connected(let segs, let added) = outcome {
                    let lead = start > 0
                        ? rescueLeadingPool(
                            before: nodes[start], afterPool: nodes[start - 1].poolIndex,
                            options: options, canonicalSize: canonicalSize
                        )
                        : nil
                    let initialSegments = lead?.segments ?? [ImageCompositor.Segment(image: nodes[start].image, overlap: 0)]
                    let skipped = Array(0..<start) + Array((start + 1)..<target)
                    return .success(InitialStep(
                        anchor: target, next: target + 1,
                        segments: initialSegments + segs,
                        skipped: skipped, backfilled: (lead?.backfilled ?? 0) + added
                    ))
                }
            }
        }
        let fallback = firstFailure ?? matchPair(nodes[0], nodes[1], options.detectorConfig)
        return .failure(.unsafeSeam(seam: StitchSeam(topIndex: 0, bottomIndex: 1, result: fallback)))
    }

    private static func walkChain(
        nodes: [Node], initial: InitialStep, maxSkip: Int,
        options: StitchEngine.Options, canonicalSize: PixelSize,
        progress: StitchEngine.ProgressHandler
    ) -> Result<ResolvedChain, StitchEngine.StitchError> {
        var segments = initial.segments
        var skipped = initial.skipped
        var backfilled = initial.backfilled
        var anchor = initial.anchor, index = initial.next
        let pairCount = max(1, nodes.count - 1)
        progress(Double(anchor) / Double(pairCount) * 0.7)

        while index < nodes.count {
            switch connect(from: nodes[anchor], to: nodes[index], options: options, canonicalSize: canonicalSize) {
            case .connected(let segs, let added):
                segments.append(contentsOf: segs); backfilled += added
                anchor = index; index += 1
            case .failed(let directResult):
                if let jumped = lookAheadSkip(
                    from: anchor, failingAt: index, nodes: nodes, maxSkip: maxSkip,
                    options: options, canonicalSize: canonicalSize
                ) {
                    skipped.append(contentsOf: index..<jumped.target)
                    segments.append(contentsOf: jumped.segments); backfilled += jumped.backfilled
                    anchor = jumped.target; index = jumped.target + 1
                } else if nodes.count - index <= maxSkip {
                    let rescue = rescueTrailingPool(
                        after: nodes[anchor], beforePool: nodes[index].poolIndex,
                        options: options, canonicalSize: canonicalSize
                    )
                    segments.append(contentsOf: rescue.segments); backfilled += rescue.backfilled
                    skipped.append(contentsOf: index..<nodes.count); index = nodes.count
                } else {
                    return .failure(.unsafeSeam(seam: StitchSeam(topIndex: anchor, bottomIndex: index, result: directResult)))
                }
            }
            progress(Double(min(anchor, pairCount)) / Double(pairCount) * 0.7)
        }
        return .success(ResolvedChain(segments: segments, skippedIndices: skipped, backfilledCount: backfilled))
    }

    private static func lookAheadSkip(
        from anchor: Int, failingAt index: Int, nodes: [Node], maxSkip: Int,
        options: StitchEngine.Options, canonicalSize: PixelSize
    ) -> (target: Int, segments: [ImageCompositor.Segment], backfilled: Int)? {
        guard maxSkip > 0, index + 1 < nodes.count else { return nil }
        let upper = min(nodes.count - 1, index + maxSkip)
        guard index + 1 <= upper else { return nil }
        for target in (index + 1)...upper {
            if case .connected(let segs, let added) = connect(
                from: nodes[anchor], to: nodes[target], options: options, canonicalSize: canonicalSize
            ) {
                return (target, segs, added)
            }
        }
        return nil
    }

    private static func connect(
        from top: Node, to bottom: Node, options: StitchEngine.Options, canonicalSize: PixelSize
    ) -> LinkOutcome {
        let direct = matchPair(top, bottom, options.detectorConfig)
        switch direct.status {
        case .matched:
            return .connected(segments: [ImageCompositor.Segment(image: bottom.image, overlap: direct.overlap)], backfilled: 0)
        case .duplicate:
            return .connected(segments: [], backfilled: 0)
        case .noOverlap:
            return .connected(segments: [ImageCompositor.Segment(image: bottom.image, overlap: 0)], backfilled: 0)
        case .ambiguous, .insufficientEvidence, .invalidInput:
            if let pL = top.poolIndex, let pR = bottom.poolIndex, pR - pL >= 2,
               let bridged = bridgePool(
                   from: top, to: bottom, range: (pL + 1)..<pR, depth: 0,
                   options: options, canonicalSize: canonicalSize
               ) {
                return .connected(segments: bridged.segments, backfilled: bridged.backfilled)
            }
            return .failed(direct)
        }
    }

    private static func bridgePool(
        from top: Node, to bottom: Node, range: Range<Int>, depth: Int,
        options: StitchEngine.Options, canonicalSize: PixelSize
    ) -> (segments: [ImageCompositor.Segment], backfilled: Int)? {
        guard depth < 3, !range.isEmpty else { return nil }
        let midIdx = (range.lowerBound + range.upperBound) / 2
        guard let midNode = loadPoolNode(at: midIdx, options: options, canonicalSize: canonicalSize) else {
            return nil
        }
        guard let left = connectOrBridge(
            from: top, to: midNode, range: range.lowerBound..<midIdx,
            depth: depth + 1, options: options, canonicalSize: canonicalSize
        ), let right = connectOrBridge(
            from: midNode, to: bottom, range: (midIdx + 1)..<range.upperBound,
            depth: depth + 1, options: options, canonicalSize: canonicalSize
        ) else { return nil }
        return (left.segments + right.segments, left.backfilled + 1 + right.backfilled)
    }

    private static func connectOrBridge(
        from top: Node, to bottom: Node, range: Range<Int>, depth: Int,
        options: StitchEngine.Options, canonicalSize: PixelSize
    ) -> (segments: [ImageCompositor.Segment], backfilled: Int)? {
        let direct = matchPair(top, bottom, options.detectorConfig)
        if direct.status == .matched {
            return ([ImageCompositor.Segment(image: bottom.image, overlap: direct.overlap)], 0)
        }
        if direct.status == .duplicate {
            return ([], 0)
        }
        return bridgePool(from: top, to: bottom, range: range, depth: depth, options: options, canonicalSize: canonicalSize)
    }

    private static func rescueLeadingPool(
        before firstValid: Node, afterPool: Int?, options: StitchEngine.Options, canonicalSize: PixelSize
    ) -> (segments: [ImageCompositor.Segment], backfilled: Int)? {
        guard let pL = afterPool, let pR = firstValid.poolIndex, pR - pL >= 2 else { return nil }
        for candidate in (pL + 1)..<pR {
            guard let node = loadPoolNode(at: candidate, options: options, canonicalSize: canonicalSize) else {
                continue
            }
            if let linked = connectOrBridge(
                from: node, to: firstValid, range: (candidate + 1)..<pR,
                depth: 0, options: options, canonicalSize: canonicalSize
            ) {
                let head = ImageCompositor.Segment(image: node.image, overlap: 0)
                let extra = linked.segments.isEmpty ? 0 : (linked.backfilled + 1)
                return ([head] + linked.segments, extra)
            }
        }
        return nil
    }

    private static func rescueTrailingPool(
        after anchor: Node, beforePool: Int?, options: StitchEngine.Options, canonicalSize: PixelSize
    ) -> (segments: [ImageCompositor.Segment], backfilled: Int) {
        guard let pL = anchor.poolIndex, let pR = beforePool, pR - pL >= 2 else { return ([], 0) }
        for candidate in stride(from: pR - 1, through: pL + 1, by: -1) {
            guard let node = loadPoolNode(at: candidate, options: options, canonicalSize: canonicalSize) else {
                continue
            }
            if let linked = connectOrBridge(
                from: anchor, to: node, range: (pL + 1)..<candidate,
                depth: 0, options: options, canonicalSize: canonicalSize
            ) {
                let extra = linked.segments.isEmpty ? 0 : (linked.backfilled + 1)
                return (linked.segments, extra)
            }
        }
        return ([], 0)
    }

    private static func loadPoolNode(
        at poolIndex: Int, options: StitchEngine.Options, canonicalSize: PixelSize
    ) -> Node? {
        guard let raw = options.backfill?.loadFrame(poolIndex),
              let cropped = try? ImageNormalizer.crop(
                  raw, topFraction: options.topCropFraction, bottomFraction: options.bottomCropFraction
              ),
              cropped.width == canonicalSize.width, cropped.height == canonicalSize.height else {
            return nil
        }
        return Node(image: cropped, buffer: PixelBuffer.from(cropped), poolIndex: poolIndex)
    }

    private static func matchPair(
        _ top: Node, _ bottom: Node, _ config: OverlapDetector.Config
    ) -> OverlapResult {
        if let topBuf = top.buffer, let bottomBuf = bottom.buffer {
            return OverlapDetector.detect(top: topBuf, bottom: bottomBuf, config: config)
        }
        return OverlapDetector.detect(top: top.image, bottom: bottom.image, config: config)
    }
}
