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
        let preservedTopRows: Int
        let preservedBottomRows: Int
    }

    private struct Node {
        let rawImage: CGImage
        let image: CGImage
        let buffer: PixelBuffer?
        let poolIndex: Int?
    }

    private struct KeptNode {
        let node: Node
        let overlap: Int
    }

    private enum LinkOutcome {
        case connected(items: [KeptNode], backfilled: Int)
        case failed(OverlapResult)
    }

    static func resolve(
        images: [CGImage],
        rawImages: [CGImage]? = nil,
        options: StitchEngine.Options,
        canonicalSize: PixelSize,
        progress: StitchEngine.ProgressHandler
    ) -> Result<ResolvedChain, StitchEngine.StitchError> {
        let poolIndices = (options.backfill?.poolIndices.count == images.count)
            ? options.backfill?.poolIndices : nil
        let hasMatchingRaws = rawImages?.count == images.count
        let nodes = images.enumerated().map { idx, img in
            let raw = hasMatchingRaws ? rawImages![idx] : img
            return Node(rawImage: raw, image: img, buffer: PixelBuffer.from(img), poolIndex: poolIndices?[idx])
        }
        if nodes.count == 1 {
            return .success(finalizeChain(
                kept: [KeptNode(node: nodes[0], overlap: 0)],
                skipped: [], backfilled: 0, options: options, canonicalSize: canonicalSize
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
        let items: [KeptNode]
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
                    let head = lead?.items ?? [KeptNode(node: nodes[start], overlap: 0)]
                    let skipped = Array(0..<start) + Array((start + 1)..<target)
                    return .success(InitialStep(
                        anchor: target, next: target + 1,
                        items: head + segs,
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
        var items = initial.items
        var skipped = initial.skipped
        var backfilled = initial.backfilled
        var anchor = initial.anchor, index = initial.next
        let pairCount = max(1, nodes.count - 1)
        progress(Double(anchor) / Double(pairCount) * 0.7)

        while index < nodes.count {
            switch connect(from: nodes[anchor], to: nodes[index], options: options, canonicalSize: canonicalSize) {
            case .connected(let segs, let added):
                items.append(contentsOf: segs); backfilled += added
                anchor = index; index += 1
            case .failed(let directResult):
                if let jumped = lookAheadSkip(
                    from: anchor, failingAt: index, nodes: nodes, maxSkip: maxSkip,
                    options: options, canonicalSize: canonicalSize
                ) {
                    skipped.append(contentsOf: index..<jumped.target)
                    items.append(contentsOf: jumped.items); backfilled += jumped.backfilled
                    anchor = jumped.target; index = jumped.target + 1
                } else if nodes.count - index <= maxSkip {
                    let rescue = rescueTrailingPool(
                        after: nodes[anchor], beforePool: nodes[index].poolIndex,
                        options: options, canonicalSize: canonicalSize
                    )
                    items.append(contentsOf: rescue.items); backfilled += rescue.backfilled
                    skipped.append(contentsOf: index..<nodes.count); index = nodes.count
                } else {
                    return .failure(.unsafeSeam(seam: StitchSeam(topIndex: anchor, bottomIndex: index, result: directResult)))
                }
            }
            progress(Double(min(anchor, pairCount)) / Double(pairCount) * 0.7)
        }
        return .success(finalizeChain(
            kept: items, skipped: skipped, backfilled: backfilled,
            options: options, canonicalSize: canonicalSize
        ))
    }

    private static func finalizeChain(
        kept: [KeptNode], skipped: [Int], backfilled: Int,
        options: StitchEngine.Options, canonicalSize: PixelSize
    ) -> ResolvedChain {
        let firstTop = resolvedFirstTopCrop(options: options)
        let lastBottom: Float = options.keepFooter ? 0 : options.bottomCropFraction
        var segments = kept.map { ImageCompositor.Segment(image: $0.node.image, overlap: $0.overlap) }
        guard !kept.isEmpty else {
            return ResolvedChain(
                segments: segments, skippedIndices: skipped, backfilledCount: backfilled,
                preservedTopRows: 0, preservedBottomRows: 0
            )
        }

        let single = kept.count == 1
        let firstBottom = single ? lastBottom : options.bottomCropFraction
        if firstTop != options.topCropFraction || firstBottom != options.bottomCropFraction,
           let recroppedFirst = try? ImageNormalizer.crop(
               kept[0].node.rawImage, topFraction: firstTop, bottomFraction: firstBottom
           ) {
            segments[0] = ImageCompositor.Segment(image: recroppedFirst, overlap: 0)
        }
        if !single, lastBottom != options.bottomCropFraction,
           let recroppedLast = try? ImageNormalizer.crop(
               kept[kept.count - 1].node.rawImage, topFraction: options.topCropFraction, bottomFraction: lastBottom
           ) {
            let lastIdx = kept.count - 1
            segments[lastIdx] = ImageCompositor.Segment(image: recroppedLast, overlap: kept[lastIdx].overlap)
        }

        let topRows = extraPreservedRows(
            rawImage: kept[0].node.rawImage, baseCrop: options.topCropFraction,
            keptCrop: firstTop, canonicalWidth: canonicalSize.width
        )
        let bottomRows = extraPreservedRows(
            rawImage: kept[kept.count - 1].node.rawImage, baseCrop: options.bottomCropFraction,
            keptCrop: lastBottom, canonicalWidth: canonicalSize.width
        )
        return ResolvedChain(
            segments: segments, skippedIndices: skipped, backfilledCount: backfilled,
            preservedTopRows: topRows, preservedBottomRows: bottomRows
        )
    }

    private static func resolvedFirstTopCrop(options: StitchEngine.Options) -> Float {
        switch options.headerMode {
        case .none:
            return options.topCropFraction
        case .navBarOnly:
            return min(options.topCropFraction, FixedBarDetector.recordingStatusBandFloor)
        case .full:
            return 0
        }
    }

    private static func extraPreservedRows(
        rawImage: CGImage, baseCrop: Float, keptCrop: Float, canonicalWidth: Int
    ) -> Int {
        let clampedBase = baseCrop.isFinite ? max(0, min(baseCrop, 0.49)) : 0
        let clampedKept = keptCrop.isFinite ? max(0, min(keptCrop, 0.49)) : 0
        let basePx = Int((Float(rawImage.height) * clampedBase).rounded(.down))
        let keptPx = Int((Float(rawImage.height) * clampedKept).rounded(.down))
        let delta = max(0, basePx - keptPx)
        guard rawImage.width > 0, canonicalWidth > 0, rawImage.width != canonicalWidth else { return delta }
        return Int((Float(delta) * Float(canonicalWidth) / Float(rawImage.width)).rounded())
    }

    private static func lookAheadSkip(
        from anchor: Int, failingAt index: Int, nodes: [Node], maxSkip: Int,
        options: StitchEngine.Options, canonicalSize: PixelSize
    ) -> (target: Int, items: [KeptNode], backfilled: Int)? {
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
            return .connected(items: [KeptNode(node: bottom, overlap: direct.overlap)], backfilled: 0)
        case .duplicate:
            return .connected(items: [], backfilled: 0)
        case .noOverlap:
            return .connected(items: [KeptNode(node: bottom, overlap: 0)], backfilled: 0)
        case .ambiguous, .insufficientEvidence, .invalidInput:
            if let pL = top.poolIndex, let pR = bottom.poolIndex, pR - pL >= 2,
               let bridged = bridgePool(
                   from: top, to: bottom, range: (pL + 1)..<pR, depth: 0,
                   options: options, canonicalSize: canonicalSize
               ) {
                return .connected(items: bridged.items, backfilled: bridged.backfilled)
            }
            return .failed(direct)
        }
    }

    private static func bridgePool(
        from top: Node, to bottom: Node, range: Range<Int>, depth: Int,
        options: StitchEngine.Options, canonicalSize: PixelSize
    ) -> (items: [KeptNode], backfilled: Int)? {
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
        return (left.items + right.items, left.backfilled + 1 + right.backfilled)
    }

    private static func connectOrBridge(
        from top: Node, to bottom: Node, range: Range<Int>, depth: Int,
        options: StitchEngine.Options, canonicalSize: PixelSize
    ) -> (items: [KeptNode], backfilled: Int)? {
        let direct = matchPair(top, bottom, options.detectorConfig)
        if direct.status == .matched {
            return ([KeptNode(node: bottom, overlap: direct.overlap)], 0)
        }
        if direct.status == .duplicate {
            return ([], 0)
        }
        return bridgePool(from: top, to: bottom, range: range, depth: depth, options: options, canonicalSize: canonicalSize)
    }

    private static func rescueLeadingPool(
        before firstValid: Node, afterPool: Int?, options: StitchEngine.Options, canonicalSize: PixelSize
    ) -> (items: [KeptNode], backfilled: Int)? {
        guard let pL = afterPool, let pR = firstValid.poolIndex, pR - pL >= 2 else { return nil }
        for candidate in (pL + 1)..<pR {
            guard let node = loadPoolNode(at: candidate, options: options, canonicalSize: canonicalSize) else {
                continue
            }
            if let linked = connectOrBridge(
                from: node, to: firstValid, range: (candidate + 1)..<pR,
                depth: 0, options: options, canonicalSize: canonicalSize
            ) {
                let head = KeptNode(node: node, overlap: 0)
                let extra = linked.items.isEmpty ? 0 : (linked.backfilled + 1)
                return ([head] + linked.items, extra)
            }
        }
        return nil
    }

    private static func rescueTrailingPool(
        after anchor: Node, beforePool: Int?, options: StitchEngine.Options, canonicalSize: PixelSize
    ) -> (items: [KeptNode], backfilled: Int) {
        guard let pL = anchor.poolIndex, let pR = beforePool, pR - pL >= 2 else { return ([], 0) }
        for candidate in stride(from: pR - 1, through: pL + 1, by: -1) {
            guard let node = loadPoolNode(at: candidate, options: options, canonicalSize: canonicalSize) else {
                continue
            }
            if let linked = connectOrBridge(
                from: anchor, to: node, range: (pL + 1)..<candidate,
                depth: 0, options: options, canonicalSize: canonicalSize
            ) {
                let extra = linked.items.isEmpty ? 0 : (linked.backfilled + 1)
                return (linked.items, extra)
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
        return Node(rawImage: raw, image: cropped, buffer: PixelBuffer.from(cropped), poolIndex: poolIndex)
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
