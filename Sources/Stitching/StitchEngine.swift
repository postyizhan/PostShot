// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreGraphics
import Foundation

enum HeaderKeepMode: String, CaseIterable, Equatable, Sendable {
    case none
    case navBarOnly
    case full
}

enum ScrollDirection: Equatable, Sendable {
    case topToBottom
    case bottomToTop
}

enum OrderAdjustment: Equatable, Sendable {
    case none
    case reversed
    case reordered
}

struct StitchSeam: Equatable {
    let topIndex: Int
    let bottomIndex: Int
    let result: OverlapResult
    let isReverseConflict: Bool

    init(topIndex: Int, bottomIndex: Int, result: OverlapResult, isReverseConflict: Bool = false) {
        self.topIndex = topIndex
        self.bottomIndex = bottomIndex
        self.result = result
        self.isReverseConflict = isReverseConflict
    }
}

/// Supplies dense intermediate frames recorded between adjacent primary frames so `StitchEngine`
/// can automatically backfill fast-scroll gaps or rescue trailing content right before an outlier.
struct FrameBackfillSource: @unchecked Sendable {
    /// Pool index corresponding to each image passed into `StitchEngine` (`count == images.count`).
    let poolIndices: [Int]
    /// Loads an uncropped full-resolution `CGImage` at `poolIndex` from the recording pool.
    let loadFrame: @Sendable (Int) -> CGImage?
}

struct StitchReport: @unchecked Sendable {
    let image: CGImage
    /// 0-based indices into the resolved top-to-bottom sequence skipped as outliers or backtracks.
    let skippedIndices: [Int]
    /// Number of intermediate frames automatically pulled from `FrameBackfillSource`.
    let backfilledCount: Int
    /// Normalized vertical spans occupied by each stitched segment (indexed in the resolved top-to-bottom order).
    let segmentSpans: [SegmentSpan]
    /// Whether the sequence was automatically reversed or reordered to top-to-bottom order.
    let orderAdjustment: OrderAdjustment
    /// Full permutation mapping each position in the resolved top-to-bottom order back to the input index.
    let resolvedOrder: [Int]
    /// Number of frames skipped specifically because of minor mid-scroll backtracks.
    let backtrackSkippedCount: Int
    /// Decoupled alignment chain retained for zero-alignment-cost output head/tail recropping.
    let resolvedChain: StitchGraphResolver.ResolvedChain?

    init(
        image: CGImage, skippedIndices: [Int], backfilledCount: Int, segmentSpans: [SegmentSpan],
        orderAdjustment: OrderAdjustment = .none, resolvedOrder: [Int] = [], backtrackSkippedCount: Int = 0,
        resolvedChain: StitchGraphResolver.ResolvedChain? = nil
    ) {
        self.image = image; self.skippedIndices = skippedIndices; self.backfilledCount = backfilledCount
        self.segmentSpans = segmentSpans; self.orderAdjustment = orderAdjustment
        self.resolvedOrder = resolvedOrder; self.backtrackSkippedCount = backtrackSkippedCount
        self.resolvedChain = resolvedChain
    }
}

final class StitchEngine: @unchecked Sendable {
    struct Options {
        var detectorConfig: OverlapDetector.Config = .init()
        var topCropFraction: Float = 0
        var bottomCropFraction: Float = 0
        var headerMode: HeaderKeepMode = .none
        var keepFooter: Bool = false
        var removeScrollIndicator: Bool = true
        /// Maximum consecutive non-connecting frames (e.g. Control Center) skipped automatically.
        var maxSkippedOutliers: Int = 3
        var backfill: FrameBackfillSource? = nil
        var autoDetectScrollDirection: Bool = true
        var allowAutoReorder: Bool = false
    }

    enum StitchError: Error {
        case noImages
        case invalidInput(profile: StitchInputProfile)
        case unsafeSeam(seam: StitchSeam)
        case compositeFailed(Error)
    }

    typealias ProgressHandler = (Double) -> Void
    typealias AsyncProgressHandler = @Sendable (Double) -> Void
    private let queue = DispatchQueue(label: "com.postshot.stitch", qos: .userInitiated)

    func stitch(
        images: [CGImage], options: Options = Options(), progress: @escaping AsyncProgressHandler,
        completion: @escaping @Sendable (Result<CGImage, StitchError>) -> Void
    ) {
        stitchWithReport(images: images, options: options, progress: progress) { result in
            completion(result.map(\.image))
        }
    }

    func stitchWithReport(
        images: [CGImage], options: Options = Options(), progress: @escaping AsyncProgressHandler,
        completion: @escaping @Sendable (Result<StitchReport, StitchError>) -> Void
    ) {
        queue.async {
            let outcome = autoreleasepool {
                self.stitchWithReportSync(images: images, options: options, progress: progress)
            }
            completion(outcome)
        }
    }

    func stitchSync(
        images rawImages: [CGImage], options: Options = Options(),
        progress: ProgressHandler = { _ in }
    ) -> Result<CGImage, StitchError> {
        stitchWithReportSync(images: rawImages, options: options, progress: progress).map(\.image)
    }

    func stitchWithReportSync(
        images rawImages: [CGImage], options: Options = Options(),
        progress: ProgressHandler = { _ in }
    ) -> Result<StitchReport, StitchError> {
        guard !rawImages.isEmpty else { return .failure(.noImages) }
        let images: [CGImage]
        switch cropAll(rawImages, options: options) {
        case .failure(let error): return .failure(error)
        case .success(let cropped): images = cropped
        }
        let profile = StitchInputValidator.validate(images)
        guard profile.isValid else { return .failure(.invalidInput(profile: profile)) }

        let resolved = StitchGraphResolver.resolve(
            images: images, rawImages: rawImages, options: options,
            canonicalSize: profile.canonicalSize, progress: progress
        )
        switch resolved {
        case .failure(let error): return .failure(error)
        case .success(let chain): return compositeChain(chain, width: profile.canonicalSize.width, options: options, progress: progress)
        }
    }

    func recomposite(
        chain: StitchGraphResolver.ResolvedChain, outputTopFraction: Float, outputBottomFraction: Float,
        removeScrollIndicator: Bool = true, completion: @escaping @Sendable (Result<StitchReport, StitchError>) -> Void
    ) {
        queue.async {
            let outcome = autoreleasepool {
                self.recompositeSync(
                    chain: chain, outputTopFraction: outputTopFraction,
                    outputBottomFraction: outputBottomFraction, removeScrollIndicator: removeScrollIndicator
                )
            }
            completion(outcome)
        }
    }

    func recompositeSync(
        chain: StitchGraphResolver.ResolvedChain, outputTopFraction: Float,
        outputBottomFraction: Float, removeScrollIndicator: Bool = true
    ) -> Result<StitchReport, StitchError> {
        let cropped = chain.segmentsWithOutputCrop(topFraction: outputTopFraction, bottomFraction: outputBottomFraction)
        let width = chain.canonicalWidth > 0 ? chain.canonicalWidth : (cropped.segments.first?.image.width ?? 0)
        return buildReport(
            segments: cropped.segments, width: width, removeScrollIndicator: removeScrollIndicator,
            preservedTopRows: cropped.preservedTopRows, preservedBottomRows: cropped.preservedBottomRows, chain: chain
        )
    }

    private func compositeChain(
        _ chain: StitchGraphResolver.ResolvedChain, width: Int, options: Options, progress: ProgressHandler
    ) -> Result<StitchReport, StitchError> {
        let result = buildReport(
            segments: chain.segments, width: width, removeScrollIndicator: options.removeScrollIndicator,
            preservedTopRows: chain.preservedTopRows, preservedBottomRows: chain.preservedBottomRows, chain: chain
        )
        if case .success = result { progress(1) }
        return result
    }

    private func buildReport(
        segments: [ImageCompositor.Segment], width: Int, removeScrollIndicator: Bool,
        preservedTopRows: Int, preservedBottomRows: Int, chain: StitchGraphResolver.ResolvedChain
    ) -> Result<StitchReport, StitchError> {
        do {
            let output = try ImageCompositor.composite(
                segments: segments, width: width, removeScrollIndicator: removeScrollIndicator,
                protectedTopRows: preservedTopRows, protectedBottomRows: preservedBottomRows
            )
            let spans = try ImageCompositor.computeSegmentSpans(segments: segments, width: width)
            return .success(StitchReport(
                image: output, skippedIndices: chain.skippedIndices, backfilledCount: chain.backfilledCount,
                segmentSpans: spans, orderAdjustment: chain.orderAdjustment,
                resolvedOrder: chain.resolvedOrder, backtrackSkippedCount: chain.backtrackSkippedCount,
                resolvedChain: chain
            ))
        } catch {
            return .failure(.compositeFailed(error))
        }
    }

    private func cropAll(_ rawImages: [CGImage], options: Options) -> Result<[CGImage], StitchError> {
        var images: [CGImage] = []
        images.reserveCapacity(rawImages.count)
        var cropDiagnostics: [InputDiagnostic] = []
        for (index, image) in rawImages.enumerated() {
            do {
                images.append(try ImageNormalizer.crop(
                    image, topFraction: options.topCropFraction, bottomFraction: options.bottomCropFraction
                ))
            } catch {
                cropDiagnostics.append(InputDiagnostic(
                    sourceIndex: index,
                    actual: PixelSize(width: image.width, height: image.height),
                    expected: nil,
                    reason: .nonPositiveDimensions
                ))
            }
        }
        if !cropDiagnostics.isEmpty {
            return .failure(.invalidInput(profile: StitchInputProfile(
                canonicalSize: PixelSize(width: 0, height: 0), diagnostics: cropDiagnostics
            )))
        }
        return .success(images)
    }
}

extension StitchGraphResolver.ResolvedChain {
    /// Applies user head/tail output trim fractions on top of the locked alignment chain without
    /// altering any internal overlap seam, clamping edge trims so first/last segments keep `>= overlap + 4` rows.
    func segmentsWithOutputCrop(
        topFraction: Float,
        bottomFraction: Float
    ) -> (segments: [ImageCompositor.Segment], preservedTopRows: Int, preservedBottomRows: Int) {
        guard !baseSegments.isEmpty else { return ([], 0, 0) }
        let clampedTop = topFraction.isFinite ? max(0, min(topFraction, 0.45)) : 0
        let clampedBottom = bottomFraction.isFinite ? max(0, min(bottomFraction, 0.45)) : 0
        let width = canonicalWidth > 0 ? canonicalWidth : (baseSegments.first?.image.width ?? 0)
        if baseSegments.count == 1 {
            return singleSegmentOutputCrop(top: clampedTop, bottom: clampedBottom, width: width)
        }
        return multiSegmentOutputCrop(top: clampedTop, bottom: clampedBottom, width: width)
    }

    private func singleSegmentOutputCrop(
        top: Float, bottom: Float, width: Int
    ) -> (segments: [ImageCompositor.Segment], preservedTopRows: Int, preservedBottomRows: Int) {
        let safeTop = top
        let safeBottom = min(bottom, max(0, 0.90 - safeTop))
        var seg = baseSegments[0]
        if let raw = firstRawImage,
           let cropped = try? ImageNormalizer.crop(raw, topFraction: safeTop, bottomFraction: safeBottom) {
            seg = ImageCompositor.Segment(image: cropped, overlap: seg.overlap, sourceIndex: seg.sourceIndex)
        }
        let topRows = firstRawImage.map {
            StitchGraphResolver.extraPreservedRows(rawImage: $0, baseCrop: alignmentTopCrop, keptCrop: safeTop, canonicalWidth: width)
        } ?? 0
        let bottomRows = (lastRawImage ?? firstRawImage).map {
            StitchGraphResolver.extraPreservedRows(rawImage: $0, baseCrop: alignmentBottomCrop, keptCrop: safeBottom, canonicalWidth: width)
        } ?? 0
        return ([seg], topRows, bottomRows)
    }

    private func multiSegmentOutputCrop(
        top: Float, bottom: Float, width: Int
    ) -> (segments: [ImageCompositor.Segment], preservedTopRows: Int, preservedBottomRows: Int) {
        var result = baseSegments
        let lastIdx = baseSegments.count - 1
        let alignTop = alignmentTopCrop.isFinite ? max(0, min(alignmentTopCrop, 0.49)) : 0
        let alignBottom = alignmentBottomCrop.isFinite ? max(0, min(alignmentBottomCrop, 0.49)) : 0

        let safeTop = clampedEdgeFraction(
            requested: top, oppositeCrop: alignBottom, rawImage: firstRawImage,
            minCanonicalHeight: max(1, baseSegments[1].overlap + 4), canonicalWidth: width
        )
        if let raw = firstRawImage, raw.height > 0,
           let cropped = try? ImageNormalizer.crop(raw, topFraction: safeTop, bottomFraction: alignBottom) {
            result[0] = ImageCompositor.Segment(image: cropped, overlap: baseSegments[0].overlap, sourceIndex: baseSegments[0].sourceIndex)
        }

        let safeBottom = clampedEdgeFraction(
            requested: bottom, oppositeCrop: alignTop, rawImage: lastRawImage,
            minCanonicalHeight: max(1, baseSegments[lastIdx].overlap + 4), canonicalWidth: width
        )
        if let raw = lastRawImage, raw.height > 0,
           let cropped = try? ImageNormalizer.crop(raw, topFraction: alignTop, bottomFraction: safeBottom) {
            result[lastIdx] = ImageCompositor.Segment(
                image: cropped, overlap: baseSegments[lastIdx].overlap, sourceIndex: baseSegments[lastIdx].sourceIndex
            )
        }

        let topRows = firstRawImage.map {
            StitchGraphResolver.extraPreservedRows(rawImage: $0, baseCrop: alignmentTopCrop, keptCrop: safeTop, canonicalWidth: width)
        } ?? 0
        let bottomRows = lastRawImage.map {
            StitchGraphResolver.extraPreservedRows(rawImage: $0, baseCrop: alignmentBottomCrop, keptCrop: safeBottom, canonicalWidth: width)
        } ?? 0
        return (result, topRows, bottomRows)
    }

    private func clampedEdgeFraction(
        requested: Float, oppositeCrop: Float, rawImage: CGImage?, minCanonicalHeight: Int, canonicalWidth: Int
    ) -> Float {
        guard let raw = rawImage, raw.height > 0 else { return requested }
        let minRawHeight: Int
        if raw.width > 0, canonicalWidth > 0, raw.width != canonicalWidth {
            minRawHeight = Int((Float(minCanonicalHeight) * Float(raw.width) / Float(canonicalWidth)).rounded(.up))
        } else {
            minRawHeight = minCanonicalHeight
        }
        let oppositePixels = Int((Float(raw.height) * oppositeCrop).rounded(.down))
        let maxEdgePixels = max(0, raw.height - oppositePixels - minRawHeight)
        let maxFraction = Float(maxEdgePixels) / Float(raw.height)
        return min(requested, max(0, maxFraction))
    }
}
