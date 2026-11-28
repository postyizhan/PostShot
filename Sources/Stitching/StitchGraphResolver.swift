// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreGraphics
import Foundation

/// Resolves a sequence of cropped frames into composable segments, automatically backfilling gaps
/// from the dense recording pool and skipping isolated outlier frames (such as Control Center).
enum StitchGraphResolver {
    private static let maxReversalEvents = 2

    struct ResolvedChain: @unchecked Sendable {
        let segments: [ImageCompositor.Segment], baseSegments: [ImageCompositor.Segment]
        let skippedIndices: [Int], backfilledCount: Int
        let preservedTopRows: Int, preservedBottomRows: Int
        let orderAdjustment: OrderAdjustment, resolvedOrder: [Int], backtrackSkippedCount: Int
        let firstRawImage: CGImage?, lastRawImage: CGImage?
        let alignmentTopCrop: Float, alignmentBottomCrop: Float, canonicalWidth: Int

        init(
            segments: [ImageCompositor.Segment], skippedIndices: [Int], backfilledCount: Int,
            preservedTopRows: Int, preservedBottomRows: Int, orderAdjustment: OrderAdjustment,
            resolvedOrder: [Int], backtrackSkippedCount: Int, baseSegments: [ImageCompositor.Segment]? = nil,
            firstRawImage: CGImage? = nil, lastRawImage: CGImage? = nil,
            alignmentTopCrop: Float = 0, alignmentBottomCrop: Float = 0, canonicalWidth: Int = 0
        ) {
            self.segments = segments; self.baseSegments = baseSegments ?? segments
            self.skippedIndices = skippedIndices; self.backfilledCount = backfilledCount
            self.preservedTopRows = preservedTopRows; self.preservedBottomRows = preservedBottomRows
            self.orderAdjustment = orderAdjustment; self.resolvedOrder = resolvedOrder
            self.backtrackSkippedCount = backtrackSkippedCount
            self.firstRawImage = firstRawImage; self.lastRawImage = lastRawImage
            self.alignmentTopCrop = alignmentTopCrop; self.alignmentBottomCrop = alignmentBottomCrop
            self.canonicalWidth = canonicalWidth
        }

        func withOrder(_ adjustment: OrderAdjustment, resolvedOrder: [Int]) -> ResolvedChain {
            ResolvedChain(
                segments: segments, skippedIndices: skippedIndices, backfilledCount: backfilledCount,
                preservedTopRows: preservedTopRows, preservedBottomRows: preservedBottomRows,
                orderAdjustment: adjustment, resolvedOrder: resolvedOrder, backtrackSkippedCount: backtrackSkippedCount,
                baseSegments: baseSegments, firstRawImage: firstRawImage, lastRawImage: lastRawImage,
                alignmentTopCrop: alignmentTopCrop, alignmentBottomCrop: alignmentBottomCrop, canonicalWidth: canonicalWidth
            )
        }
    }

    private struct Node { let rawImage: CGImage, image: CGImage, buffer: PixelBuffer?, poolIndex: Int?, sourceIndex: Int? }
    private struct KeptNode { let node: Node; let overlap: Int }
    private struct Context { let options: StitchEngine.Options; let canonicalSize: PixelSize }
    private enum LinkOutcome { case connected(items: [KeptNode], backfilled: Int), failed(OverlapResult) }
    private struct WalkState {
        var items: [KeptNode], skipped: [Int], backfilled: Int
        var backtrackSkippedCount = 0, reversalEvents = 0, anchor: Int, index: Int
    }
    private struct InitialStep { let anchor: Int, next: Int, items: [KeptNode], skipped: [Int], backfilled: Int }

    static func resolve(
        images: [CGImage], rawImages: [CGImage]? = nil, options: StitchEngine.Options,
        canonicalSize: PixelSize, progress: StitchEngine.ProgressHandler
    ) -> Result<ResolvedChain, StitchEngine.StitchError> {
        let ctx = Context(options: options, canonicalSize: canonicalSize)
        let poolIndices = (options.backfill?.poolIndices.count == images.count) ? options.backfill?.poolIndices : nil
        if images.count == 1 {
            let raw = (rawImages?.count == 1) ? rawImages![0] : images[0]
            let node = Node(rawImage: raw, image: images[0], buffer: PixelBuffer.from(images[0]), poolIndex: poolIndices?[0], sourceIndex: 0)
            return .success(finalizeChain(kept: [KeptNode(node: node, overlap: 0)], skipped: [], backfilled: 0, ctx: ctx, orderAdjustment: .none, resolvedOrder: [0], backtrackSkippedCount: 0))
        }
        switch orientInputs(images: images, rawImages: rawImages, poolIndices: poolIndices, ctx: ctx) {
        case .failure(let error):
            return tryScrambledReorder(originalImages: images, originalRawImages: rawImages, originalPoolIndices: poolIndices, ctx: ctx, progress: progress).map { .success($0) } ?? .failure(error)
        case .success(let oriented):
            return resolveOriented(oriented, images: images, rawImages: rawImages, poolIndices: poolIndices, ctx: ctx, progress: progress)
        }
    }

    private static func resolveOriented(
        _ oriented: (nodes: [Node], orderAdjustment: OrderAdjustment, resolvedOrder: [Int]),
        images: [CGImage], rawImages: [CGImage]?, poolIndices: [Int]?, ctx: Context, progress: StitchEngine.ProgressHandler
    ) -> Result<ResolvedChain, StitchEngine.StitchError> {
        let maxSkip = max(0, ctx.options.maxSkippedOutliers)
        let monotonic: Result<ResolvedChain, StitchEngine.StitchError>
        switch findInitialConnection(nodes: oriented.nodes, maxSkip: maxSkip, ctx: ctx) {
        case .failure(let error): monotonic = .failure(error)
        case .success(let start):
            monotonic = walkChain(
                nodes: oriented.nodes, initial: start, maxSkip: maxSkip, ctx: ctx,
                orderAdjustment: oriented.orderAdjustment, resolvedOrder: oriented.resolvedOrder, progress: progress
            )
        }
        let nonBacktrackSkips = (try? monotonic.get()).map { $0.skippedIndices.count - $0.backtrackSkippedCount } ?? Int.max
        let currentSkips = (try? monotonic.get())?.skippedIndices.count ?? Int.max
        if nonBacktrackSkips > 0, let reordered = tryScrambledReorder(
            originalImages: images, originalRawImages: rawImages, originalPoolIndices: poolIndices, ctx: ctx, progress: progress
        ), reordered.skippedIndices.count < currentSkips {
            return .success(reordered)
        }
        if case .failure(.unsafeSeam(let seam)) = monotonic, oriented.orderAdjustment == .reversed,
           oriented.resolvedOrder.indices.contains(seam.topIndex),
           oriented.resolvedOrder.indices.contains(seam.bottomIndex) {
            let a = oriented.resolvedOrder[seam.topIndex], b = oriented.resolvedOrder[seam.bottomIndex]
            return .failure(.unsafeSeam(seam: StitchSeam(topIndex: min(a, b), bottomIndex: max(a, b), result: seam.result, isReverseConflict: seam.isReverseConflict)))
        }
        return monotonic
    }

    private static func orientInputs(
        images: [CGImage], rawImages: [CGImage]?, poolIndices: [Int]?, ctx: Context
    ) -> Result<(nodes: [Node], orderAdjustment: OrderAdjustment, resolvedOrder: [Int]), StitchEngine.StitchError> {
        let identity = Array(0..<images.count), rawBuffers = images.map { PixelBuffer.from($0) }
        var order = identity, adjustment: OrderAdjustment = .none
        if ctx.options.autoDetectScrollDirection {
            let analysis = ScrollDirectionResolver.analyze(buffers: rawBuffers, poolIndices: poolIndices, options: ctx.options, canonicalSize: ctx.canonicalSize)
            if analysis.isHeavyZigZag {
                let pair = analysis.firstConflictPair ?? (0, 1)
                let result = analysis.firstConflictResult ?? OverlapDetector.detect(top: images[pair.top], bottom: images[pair.bottom], config: ctx.options.detectorConfig)
                return .failure(.unsafeSeam(seam: StitchSeam(topIndex: pair.top, bottomIndex: pair.bottom, result: result, isReverseConflict: true)))
            }
            if analysis.direction == .bottomToTop { order = Array(identity.reversed()); adjustment = .reversed }
        }
        let hasMatchingRaws = rawImages?.count == images.count
        let nodes = order.enumerated().map { resolvedIdx, origIdx in
            let img = images[origIdx]
            return Node(rawImage: hasMatchingRaws ? rawImages![origIdx] : img, image: img, buffer: rawBuffers[origIdx], poolIndex: poolIndices?[origIdx], sourceIndex: resolvedIdx)
        }
        return .success((nodes, adjustment, order))
    }

    private static func tryScrambledReorder(
        originalImages: [CGImage], originalRawImages: [CGImage]?, originalPoolIndices: [Int]?,
        ctx: Context, progress: StitchEngine.ProgressHandler
    ) -> ResolvedChain? {
        guard ctx.options.allowAutoReorder, originalImages.count >= 2,
              originalImages.count <= ScreenshotSequenceOrderer.maximumAutomaticCount,
              let recovered = ScreenshotSequenceOrderer.order(
                  images: originalImages, topCropFraction: 0, bottomCropFraction: 0, detectorConfig: ctx.options.detectorConfig
              ), recovered != Array(0..<originalImages.count) else { return nil }
        let seen = Set(recovered)
        let fullOrder = recovered + (0..<originalImages.count).filter { !seen.contains($0) }
        let reorderedImages = fullOrder.map { originalImages[$0] }
        let reorderedRaws = originalRawImages.map { raws in fullOrder.map { raws[$0] } }
        var optionsCopy = ctx.options
        optionsCopy.autoDetectScrollDirection = false
        optionsCopy.allowAutoReorder = false
        if let pools = originalPoolIndices, let bf = ctx.options.backfill {
            optionsCopy.backfill = FrameBackfillSource(poolIndices: fullOrder.map { pools[$0] }, loadFrame: bf.loadFrame)
        }
        guard case .success(let chain) = resolve(
            images: reorderedImages, rawImages: reorderedRaws, options: optionsCopy,
            canonicalSize: ctx.canonicalSize, progress: progress
        ) else { return nil }
        return chain.withOrder(.reordered, resolvedOrder: fullOrder)
    }

    private static func findInitialConnection(
        nodes: [Node], maxSkip: Int, ctx: Context
    ) -> Result<InitialStep, StitchEngine.StitchError> {
        let count = nodes.count
        var firstFailure: OverlapResult?
        let maxStart = min(maxSkip, count - 2)
        for start in 0...maxStart {
            let maxTarget = min(count - 1, start + 1 + maxSkip)
            for target in (start + 1)...maxTarget {
                let outcome = connect(from: nodes[start], to: nodes[target], ctx: ctx)
                if start == 0, target == 1, case .failed(let res) = outcome { firstFailure = res }
                if case .connected(let segs, let added) = outcome {
                    let lead = start > 0 ? rescueLeadingPool(before: nodes[start], afterPool: nodes[start - 1].poolIndex, ctx: ctx) : nil
                    let head = lead?.items ?? [KeptNode(node: nodes[start], overlap: 0)]
                    let skipped = Array(0..<start) + Array((start + 1)..<target)
                    return .success(InitialStep(
                        anchor: target, next: target + 1, items: head + segs,
                        skipped: skipped, backfilled: (lead?.backfilled ?? 0) + added
                    ))
                }
            }
        }
        let fallback = firstFailure ?? matchPair(nodes[0], nodes[1], ctx.options.detectorConfig)
        let isRev = ScrollDirectionResolver.isReversePair(nodes[0].buffer, nodes[1].buffer, config: ctx.options.detectorConfig)
        return .failure(.unsafeSeam(seam: StitchSeam(topIndex: 0, bottomIndex: 1, result: fallback, isReverseConflict: isRev)))
    }

    private static func walkChain(
        nodes: [Node], initial: InitialStep, maxSkip: Int, ctx: Context,
        orderAdjustment: OrderAdjustment, resolvedOrder: [Int], progress: StitchEngine.ProgressHandler
    ) -> Result<ResolvedChain, StitchEngine.StitchError> {
        var state = WalkState(items: initial.items, skipped: initial.skipped, backfilled: initial.backfilled, anchor: initial.anchor, index: initial.next)
        let buffers = nodes.map(\.buffer)
        let pairCount = max(1, nodes.count - 1)
        progress(Double(state.anchor) / Double(pairCount) * 0.7)

        while state.index < nodes.count {
            switch connect(from: nodes[state.anchor], to: nodes[state.index], ctx: ctx) {
            case .connected(let segs, let added):
                state.items.append(contentsOf: segs); state.backfilled += added
                state.anchor = state.index; state.index += 1
            case .failed(let directResult):
                if let error = handleStepFailure(directResult: directResult, state: &state, nodes: nodes, buffers: buffers, maxSkip: maxSkip, ctx: ctx) {
                    return .failure(error)
                }
            }
            progress(Double(min(state.anchor, pairCount)) / Double(pairCount) * 0.7)
        }
        return .success(finalizeChain(
            kept: state.items, skipped: state.skipped, backfilled: state.backfilled, ctx: ctx,
            orderAdjustment: orderAdjustment, resolvedOrder: resolvedOrder, backtrackSkippedCount: state.backtrackSkippedCount
        ))
    }

    private static func handleStepFailure(
        directResult: OverlapResult, state: inout WalkState, nodes: [Node],
        buffers: [PixelBuffer?], maxSkip: Int, ctx: Context
    ) -> StitchEngine.StitchError? {
        let backtrack = ScrollDirectionResolver.detectMinorBacktrackSkip(
            anchor: state.anchor, failingAt: state.index, buffers: buffers, config: ctx.options.detectorConfig
        ) { fromIdx, toIdx -> (items: [KeptNode], backfilled: Int)? in
            if case .connected(let segs, let added) = connect(from: nodes[fromIdx], to: nodes[toIdx], ctx: ctx) { return (segs, added) }
            return nil
        }
        switch backtrack {
        case .excessiveBacktrack(let failIdx):
            return .unsafeSeam(seam: StitchSeam(topIndex: state.anchor, bottomIndex: failIdx, result: directResult, isReverseConflict: true))
        case .reconnected(let target, let conn, let skippedCount):
            state.reversalEvents += 1
            guard state.reversalEvents <= maxReversalEvents else {
                return .unsafeSeam(seam: StitchSeam(topIndex: state.anchor, bottomIndex: state.index, result: directResult, isReverseConflict: true))
            }
            state.skipped.append(contentsOf: state.index..<target)
            state.items.append(contentsOf: conn.items); state.backfilled += conn.backfilled
            state.backtrackSkippedCount += skippedCount; state.anchor = target; state.index = target + 1
            return nil
        case .trailingBacktrack(let skippedCount):
            state.reversalEvents += 1
            guard state.reversalEvents <= maxReversalEvents else {
                return .unsafeSeam(seam: StitchSeam(topIndex: state.anchor, bottomIndex: state.index, result: directResult, isReverseConflict: true))
            }
            finishTrailingRescue(state: &state, nodes: nodes, backtrackSkipped: skippedCount, ctx: ctx)
            return nil
        case .none:
            return handleNonBacktrackFailure(directResult: directResult, state: &state, nodes: nodes, maxSkip: maxSkip, ctx: ctx)
        }
    }

    private static func handleNonBacktrackFailure(
        directResult: OverlapResult, state: inout WalkState, nodes: [Node], maxSkip: Int, ctx: Context
    ) -> StitchEngine.StitchError? {
        if let jumped = lookAheadSkip(from: state.anchor, failingAt: state.index, nodes: nodes, maxSkip: maxSkip, ctx: ctx) {
            state.skipped.append(contentsOf: state.index..<jumped.target)
            state.items.append(contentsOf: jumped.items); state.backfilled += jumped.backfilled
            state.anchor = jumped.target; state.index = jumped.target + 1
            return nil
        }
        if nodes.count - state.index <= maxSkip {
            finishTrailingRescue(state: &state, nodes: nodes, backtrackSkipped: 0, ctx: ctx)
            return nil
        }
        let isRev = ScrollDirectionResolver.isReversePair(nodes[state.anchor].buffer, nodes[state.index].buffer, config: ctx.options.detectorConfig)
        return .unsafeSeam(seam: StitchSeam(topIndex: state.anchor, bottomIndex: state.index, result: directResult, isReverseConflict: isRev))
    }

    private static func finishTrailingRescue(state: inout WalkState, nodes: [Node], backtrackSkipped: Int, ctx: Context) {
        let rescue = rescueTrailingPool(after: nodes[state.anchor], beforePool: nodes[state.index].poolIndex, ctx: ctx)
        state.items.append(contentsOf: rescue.items); state.backfilled += rescue.backfilled
        state.skipped.append(contentsOf: state.index..<nodes.count)
        state.backtrackSkippedCount += backtrackSkipped
        state.index = nodes.count
    }

    private static func finalizeChain(
        kept: [KeptNode], skipped: [Int], backfilled: Int, ctx: Context,
        orderAdjustment: OrderAdjustment, resolvedOrder: [Int], backtrackSkippedCount: Int
    ) -> ResolvedChain {
        let firstTop: Float = ctx.options.headerMode == .full ? 0 : (
            ctx.options.headerMode == .navBarOnly ? min(ctx.options.topCropFraction, FixedBarDetector.recordingStatusBandFloor) : ctx.options.topCropFraction
        )
        let lastBottom: Float = ctx.options.keepFooter ? 0 : ctx.options.bottomCropFraction
        let baseSegments = kept.map { ImageCompositor.Segment(image: $0.node.image, overlap: $0.overlap, sourceIndex: $0.node.sourceIndex) }
        var segments = baseSegments
        guard !kept.isEmpty else {
            return ResolvedChain(
                segments: segments, skippedIndices: skipped, backfilledCount: backfilled, preservedTopRows: 0, preservedBottomRows: 0,
                orderAdjustment: orderAdjustment, resolvedOrder: resolvedOrder, backtrackSkippedCount: backtrackSkippedCount,
                baseSegments: baseSegments, alignmentTopCrop: ctx.options.topCropFraction,
                alignmentBottomCrop: ctx.options.bottomCropFraction, canonicalWidth: ctx.canonicalSize.width
            )
        }
        let single = kept.count == 1, firstBottom = single ? lastBottom : ctx.options.bottomCropFraction
        if firstTop != ctx.options.topCropFraction || firstBottom != ctx.options.bottomCropFraction,
           let recropped = try? ImageNormalizer.crop(kept[0].node.rawImage, topFraction: firstTop, bottomFraction: firstBottom) {
            segments[0] = ImageCompositor.Segment(image: recropped, overlap: 0, sourceIndex: kept[0].node.sourceIndex)
        }
        if !single, lastBottom != ctx.options.bottomCropFraction,
           let recropped = try? ImageNormalizer.crop(kept[kept.count - 1].node.rawImage, topFraction: ctx.options.topCropFraction, bottomFraction: lastBottom) {
            let lastIdx = kept.count - 1
            segments[lastIdx] = ImageCompositor.Segment(image: recropped, overlap: kept[lastIdx].overlap, sourceIndex: kept[lastIdx].node.sourceIndex)
        }
        let topRows = extraPreservedRows(rawImage: kept[0].node.rawImage, baseCrop: ctx.options.topCropFraction, keptCrop: firstTop, canonicalWidth: ctx.canonicalSize.width)
        let bottomRows = extraPreservedRows(rawImage: kept[kept.count - 1].node.rawImage, baseCrop: ctx.options.bottomCropFraction, keptCrop: lastBottom, canonicalWidth: ctx.canonicalSize.width)
        return ResolvedChain(
            segments: segments, skippedIndices: skipped, backfilledCount: backfilled, preservedTopRows: topRows, preservedBottomRows: bottomRows,
            orderAdjustment: orderAdjustment, resolvedOrder: resolvedOrder, backtrackSkippedCount: backtrackSkippedCount,
            baseSegments: baseSegments, firstRawImage: kept.first?.node.rawImage, lastRawImage: kept.last?.node.rawImage,
            alignmentTopCrop: ctx.options.topCropFraction, alignmentBottomCrop: ctx.options.bottomCropFraction, canonicalWidth: ctx.canonicalSize.width
        )
    }

    static func extraPreservedRows(rawImage: CGImage, baseCrop: Float, keptCrop: Float, canonicalWidth: Int) -> Int {
        let clampedBase = baseCrop.isFinite ? max(0, min(baseCrop, 0.49)) : 0
        let clampedKept = keptCrop.isFinite ? max(0, min(keptCrop, 0.49)) : 0
        let delta = max(0, Int((Float(rawImage.height) * clampedBase).rounded(.down)) - Int((Float(rawImage.height) * clampedKept).rounded(.down)))
        guard rawImage.width > 0, canonicalWidth > 0, rawImage.width != canonicalWidth else { return delta }
        return Int((Float(delta) * Float(canonicalWidth) / Float(rawImage.width)).rounded())
    }

    private static func lookAheadSkip(
        from anchor: Int, failingAt index: Int, nodes: [Node], maxSkip: Int, ctx: Context
    ) -> (target: Int, items: [KeptNode], backfilled: Int)? {
        guard maxSkip > 0, index + 1 < nodes.count else { return nil }
        let upper = min(nodes.count - 1, index + maxSkip)
        guard index + 1 <= upper else { return nil }
        for target in (index + 1)...upper {
            if case .connected(let segs, let added) = connect(from: nodes[anchor], to: nodes[target], ctx: ctx) { return (target, segs, added) }
        }
        return nil
    }

    private static func connect(from top: Node, to bottom: Node, ctx: Context) -> LinkOutcome {
        let direct = matchPair(top, bottom, ctx.options.detectorConfig)
        switch direct.status {
        case .matched: return .connected(items: [KeptNode(node: bottom, overlap: direct.overlap)], backfilled: 0)
        case .duplicate: return .connected(items: [], backfilled: 0)
        case .noOverlap: return .connected(items: [KeptNode(node: bottom, overlap: 0)], backfilled: 0)
        case .ambiguous, .insufficientEvidence, .invalidInput:
            if let pL = top.poolIndex, let pR = bottom.poolIndex, let span = PoolSpan.between(pL, pR),
               let bridged = bridgePool(from: top, to: bottom, span: span, depth: 0, ctx: ctx) {
                return .connected(items: bridged.items, backfilled: bridged.backfilled)
            }
            return .failed(direct)
        }
    }

    private static func bridgePool(from top: Node, to bottom: Node, span: PoolSpan?, depth: Int, ctx: Context) -> (items: [KeptNode], backfilled: Int)? {
        guard depth < 3, let span, span.count > 0,
              let midNode = loadPoolNode(at: span.poolIndex(at: span.midOffset), ctx: ctx),
              let left = connectOrBridge(from: top, to: midNode, span: span.leftHalf, depth: depth + 1, ctx: ctx),
              let right = connectOrBridge(from: midNode, to: bottom, span: span.rightHalf, depth: depth + 1, ctx: ctx)
        else { return nil }
        return (left.items + right.items, left.backfilled + 1 + right.backfilled)
    }

    private static func connectOrBridge(from top: Node, to bottom: Node, span: PoolSpan?, depth: Int, ctx: Context) -> (items: [KeptNode], backfilled: Int)? {
        let direct = matchPair(top, bottom, ctx.options.detectorConfig)
        if direct.status == .matched { return ([KeptNode(node: bottom, overlap: direct.overlap)], 0) }
        if direct.status == .duplicate { return ([], 0) }
        return bridgePool(from: top, to: bottom, span: span, depth: depth, ctx: ctx)
    }

    private static func rescueLeadingPool(before firstValid: Node, afterPool: Int?, ctx: Context) -> (items: [KeptNode], backfilled: Int)? {
        guard let pL = afterPool, let pR = firstValid.poolIndex, let span = PoolSpan.between(pL, pR) else { return nil }
        for offset in span.offsets {
            guard let node = loadPoolNode(at: span.poolIndex(at: offset), ctx: ctx),
                  let linked = connectOrBridge(from: node, to: firstValid, span: span.suffix(after: offset), depth: 0, ctx: ctx) else { continue }
            return ([KeptNode(node: node, overlap: 0)] + linked.items, linked.items.isEmpty ? 0 : (linked.backfilled + 1))
        }
        return nil
    }

    private static func rescueTrailingPool(after anchor: Node, beforePool: Int?, ctx: Context) -> (items: [KeptNode], backfilled: Int) {
        guard let pL = anchor.poolIndex, let pR = beforePool, let span = PoolSpan.between(pL, pR) else { return ([], 0) }
        for offset in span.offsets.reversed() {
            guard let node = loadPoolNode(at: span.poolIndex(at: offset), ctx: ctx),
                  let linked = connectOrBridge(from: anchor, to: node, span: span.prefix(upTo: offset), depth: 0, ctx: ctx) else { continue }
            return (linked.items, linked.items.isEmpty ? 0 : (linked.backfilled + 1))
        }
        return ([], 0)
    }

    private static func loadPoolNode(at poolIndex: Int, ctx: Context) -> Node? {
        guard let raw = ctx.options.backfill?.loadFrame(poolIndex),
              let cropped = try? ImageNormalizer.crop(raw, topFraction: ctx.options.topCropFraction, bottomFraction: ctx.options.bottomCropFraction),
              cropped.width == ctx.canonicalSize.width, cropped.height == ctx.canonicalSize.height else { return nil }
        return Node(rawImage: raw, image: cropped, buffer: PixelBuffer.from(cropped), poolIndex: poolIndex, sourceIndex: nil)
    }

    private static func matchPair(_ top: Node, _ bottom: Node, _ config: OverlapDetector.Config) -> OverlapResult {
        if let topBuf = top.buffer, let bottomBuf = bottom.buffer {
            return OverlapDetector.detect(top: topBuf, bottom: bottomBuf, config: config)
        }
        return OverlapDetector.detect(top: top.image, bottom: bottom.image, config: config)
    }
}
