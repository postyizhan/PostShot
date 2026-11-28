// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import PhotosUI
import CoreGraphics

/// Wraps a stitched `CGImage` along with source metadata and segment spans.
struct StitchResult: Identifiable {
    let id = UUID()
    let image: CGImage
    /// De-duplicated PHAsset local identifiers of the images that were stitched.
    let sourceAssetIdentifiers: [String]
    /// Normalized top-down vertical spans occupied by each stitched segment.
    let segmentSpans: [SegmentSpan]

    init(image: CGImage, sourceAssetIdentifiers: [String], segmentSpans: [SegmentSpan] = []) {
        self.image = image; self.sourceAssetIdentifiers = sourceAssetIdentifiers; self.segmentSpans = segmentSpans
    }
}

/// Owns selection, loading, auto-crop detection, backfill source, and stitching state.
@MainActor
final class StitchViewModel: ObservableObject {
    struct EditRestoreSnapshot {
        let images: [SelectedImage]; let result: StitchResult?; let cachedChain: StitchGraphResolver.ResolvedChain?
        let alignmentTopCrop: Float, alignmentBottomCrop: Float
        let topCropFraction: Float, bottomCropFraction: Float
        let headerMode: HeaderKeepMode, keepFooter: Bool; let stitchNotice: String?
    }

    @Published var pickerItems: [PhotosPickerItem] = [] { didSet { loadPickedItems() } }
    @Published var images: [SelectedImage] = [] {
        didSet { stitchGeneration &+= 1; cachedChain = nil; failedSeam = nil }
    }
    @Published var isStitching = false
    @Published var progress: Double = 0
    @Published var result: StitchResult?

    private(set) var alignmentTopCrop: Float = 0
    private(set) var alignmentBottomCrop: Float = 0
    @Published var topCropFraction: Float = 0
    @Published var bottomCropFraction: Float = 0
    @Published var headerMode: HeaderKeepMode = .none
    @Published var keepFooter: Bool = false
    @Published var removeScrollIndicator: Bool = true

    @Published var isShowingError = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var failedSeam: StitchSeam?
    @Published private(set) var stitchNotice: String?
    private(set) var cachedChain: StitchGraphResolver.ResolvedChain?

    var effectiveOutputTopCrop: Float {
        switch headerMode {
        case .none: return topCropFraction
        case .navBarOnly: return min(alignmentTopCrop, FixedBarDetector.recordingStatusBandFloor)
        case .full: return 0
        }
    }

    var effectiveOutputBottomCrop: Float { keepFooter ? 0 : bottomCropFraction }

    private let engine = StitchEngine()
    private let autoSuggestCrop: Bool
    private var lastSuggestedCrop: (top: Float, bottom: Float)?
    private var isRecordingSource = false
    private var recordingStore: CaptureFrameStore?
    private var stitchGeneration = 0
    private var loadTask: Task<Void, Never>?
    private var cropTask: Task<Void, Never>?

    init(autoSuggestCrop: Bool = false) {
        self.autoSuggestCrop = autoSuggestCrop
    }

    // MARK: - Selection

    func clear() {
        loadTask?.cancel(); cropTask?.cancel()
        stitchGeneration &+= 1; isStitching = false
        pickerItems = []; images = []; result = nil; cachedChain = nil
        alignmentTopCrop = 0; alignmentBottomCrop = 0
        topCropFraction = 0; bottomCropFraction = 0
        headerMode = .none; keepFooter = false
        failedSeam = nil; errorMessage = nil; stitchNotice = nil; isShowingError = false
        lastSuggestedCrop = nil; recordingStore = nil
    }

    /// Seeds already-decoded canonical images, preserving their validated order.
    func load(decodedImages: [SelectedImage]) {
        isRecordingSource = false; recordingStore = nil; stitchNotice = nil
        images = decodedImages; result = nil; errorMessage = nil; isShowingError = false
    }

    func notePreExcluded(indices: [Int]) {
        guard !indices.isEmpty else { return }
        let labels = indices.map { String($0 + 1) }.joined(separator: "、")
        stitchNotice = "已自动排除第 \(labels) 张不衔接截图"
    }

    /// Loads sparse primary keyframes from `CaptureFrameStore` while retaining the full disk pool
    /// so `StitchEngine` can backfill intermediate frames on demand.
    func loadFromStore(_ store: CaptureFrameStore) async {
        let outcome = await Task.detached(priority: .userInitiated) {
            let indices = store.selectPrimaryIndices()
            var loaded: [SelectedImage] = [], failedIndices: [Int] = []
            for (pos, poolIdx) in indices.enumerated() {
                do {
                    var item = try store.loadSelectedImage(at: poolIdx)
                    item.poolIndex = poolIdx; loaded.append(item)
                } catch { failedIndices.append(pos) }
            }
            return (loaded, failedIndices)
        }.value
        isRecordingSource = true; recordingStore = store; stitchNotice = nil
        applyLoadedFrames(outcome.0, failedIndices: outcome.1, prefix: "采集帧")
    }

    /// Loads captured frames off the main actor while preserving adjacency.
    func loadAsync(pngFrames: [Data]) async {
        let outcome = await Task.detached(priority: .userInitiated) { Self.decodePNGFrames(pngFrames) }.value
        isRecordingSource = true; recordingStore = nil; stitchNotice = nil
        applyLoadedFrames(outcome.0, failedIndices: outcome.1, prefix: "采集帧")
    }

    /// Synchronous convenience wrapper for tests or small pre-loaded batches.
    func load(pngFrames: [Data]) {
        let outcome = Self.decodePNGFrames(pngFrames)
        isRecordingSource = true; recordingStore = nil; stitchNotice = nil
        applyLoadedFrames(outcome.0, failedIndices: outcome.1, prefix: "采集帧")
    }

    nonisolated private static func decodePNGFrames(_ pngFrames: [Data]) -> ([SelectedImage], [Int]) {
        var loaded: [SelectedImage] = [], failedIndices: [Int] = []
        for (index, png) in pngFrames.enumerated() {
            do { loaded.append(try ImageDecoder.decode(png)) } catch { failedIndices.append(index) }
        }
        return (loaded, failedIndices)
    }

    private func applyLoadedFrames(_ loaded: [SelectedImage], failedIndices: [Int], prefix: String) {
        result = nil
        guard failedIndices.isEmpty else { images = []; present(error: failedLoadMessage(prefix: prefix, indices: failedIndices)); return }
        errorMessage = nil; isShowingError = false; images = loaded
    }

    func suggestFixedBarCrop() {
        guard images.count >= 2 else { return }
        applySuggestedCrop(FixedBarDetector.detectFractions(images.map(\.cgImage), minimumTopFraction: minimumTopCrop))
    }

    func suggestFixedBarCropAsync() async {
        guard images.count >= 2 else { return }
        let expectedGen = stitchGeneration, cgImages = images.map(\.cgImage), floor = minimumTopCrop
        let suggestion = await Task.detached(priority: .userInitiated) {
            FixedBarDetector.detectFractions(cgImages, minimumTopFraction: floor)
        }.value
        guard stitchGeneration == expectedGen else { return }
        applySuggestedCrop(suggestion)
    }

    private var minimumTopCrop: Float { isRecordingSource ? FixedBarDetector.recordingStatusBandFloor : 0 }

    func applyDetectedFixedBarCrop(top: Float, bottom: Float) {
        applySuggestedCrop((top: top, bottom: bottom))
    }

    private func applySuggestedCrop(_ suggestion: (top: Float, bottom: Float)) {
        alignmentTopCrop = suggestion.top; alignmentBottomCrop = suggestion.bottom
        topCropFraction = suggestion.top; bottomCropFraction = suggestion.bottom
        lastSuggestedCrop = suggestion
    }

    private func refreshAutoCropAndStitchIfReady() {
        guard images.count >= 2 else { return }
        let shouldRefresh = autoSuggestCrop && (lastSuggestedCrop.map {
            abs(topCropFraction - $0.top) < 1e-4 && abs(bottomCropFraction - $0.bottom) < 1e-4
        } ?? true)
        cropTask?.cancel()
        cropTask = Task {
            if shouldRefresh { await suggestFixedBarCropAsync() }
            guard !Task.isCancelled, images.count >= 2 else { return }
            stitch()
        }
    }

    private func loadPickedItems() {
        loadTask?.cancel()
        let items = pickerItems
        guard !items.isEmpty else { images = []; stitchNotice = nil; return }

        loadTask = Task {
            var loaded: [SelectedImage] = [], failedIndices: [Int] = []
            for (index, item) in items.enumerated() {
                guard !Task.isCancelled else { return }
                do {
                    if let decoded = try await decodePickerItem(item) { loaded.append(decoded) }
                    else { failedIndices.append(index) }
                } catch is CancellationError { return } catch { failedIndices.append(index) }
            }
            guard !Task.isCancelled, items == self.pickerItems else { return }
            isRecordingSource = false; recordingStore = nil; stitchNotice = nil
            applyLoadedFrames(loaded, failedIndices: failedIndices, prefix: "所选图片")
            if autoSuggestCrop, failedIndices.isEmpty, loaded.count >= 2 { await suggestFixedBarCropAsync() }
        }
    }

    private func decodePickerItem(_ item: PhotosPickerItem) async throws -> SelectedImage? {
        guard let data = try await item.loadTransferable(type: Data.self) else { return nil }
        let assetID = item.itemIdentifier
        return try await Task.detached(priority: .userInitiated) {
            try ImageDecoder.decode(data, assetIdentifier: assetID)
        }.value
    }

    // MARK: - Stitching

    func stitch() {
        guard images.count >= 2, !isStitching else { return }
        stitchGeneration &+= 1
        let expectedGen = stitchGeneration
        result = nil; failedSeam = nil; errorMessage = nil; isShowingError = false
        isStitching = true; progress = 0

        var options = StitchEngine.Options()
        options.topCropFraction = alignmentTopCrop; options.bottomCropFraction = alignmentBottomCrop
        options.headerMode = headerMode; options.keepFooter = keepFooter
        options.removeScrollIndicator = removeScrollIndicator
        options.autoDetectScrollDirection = true; options.allowAutoReorder = !isRecordingSource
        if let store = recordingStore {
            let indices = images.compactMap(\.poolIndex)
            if indices.count == images.count {
                options.backfill = FrameBackfillSource(poolIndices: indices, loadFrame: { store.loadCGImage(at: $0) })
            }
        }
        let cgImages = images.map(\.cgImage)

        engine.stitchWithReport(images: cgImages, options: options) { [weak self] value in
            Task { @MainActor in
                guard let self, self.stitchGeneration == expectedGen else { return }
                self.progress = value
            }
        } completion: { [weak self] outcome in
            Task { @MainActor in
                guard let self, self.stitchGeneration == expectedGen else { return }
                self.isStitching = false; self.handleStitchOutcome(outcome)
            }
        }
    }

    func recompositeOutput() {
        guard images.count >= 2, !isStitching else { return }
        guard let chain = cachedChain else { stitch(); return }
        stitchGeneration &+= 1
        let expectedGen = stitchGeneration
        errorMessage = nil; isShowingError = false; isStitching = true
        engine.recomposite(
            chain: chain, outputTopFraction: effectiveOutputTopCrop,
            outputBottomFraction: effectiveOutputBottomCrop, removeScrollIndicator: removeScrollIndicator
        ) { [weak self] outcome in
            Task { @MainActor in
                guard let self, self.stitchGeneration == expectedGen else { return }
                self.isStitching = false
                switch outcome {
                case .success(let report):
                    self.cachedChain = report.resolvedChain ?? chain
                    let ids = Array(Set(self.images.compactMap(\.assetIdentifier)))
                    self.result = StitchResult(image: report.image, sourceAssetIdentifiers: ids, segmentSpans: report.segmentSpans)
                case .failure(let error): self.present(error: self.describe(error))
                }
            }
        }
    }

    func resetOutputCropToAutoDetected() async {
        guard images.count >= 2, !isStitching else { return }
        if cachedChain != nil {
            topCropFraction = alignmentTopCrop; bottomCropFraction = alignmentBottomCrop
            headerMode = .none; keepFooter = false; recompositeOutput()
        } else {
            await suggestFixedBarCropAsync()
            guard !Task.isCancelled, images.count >= 2, !isStitching else { return }
            headerMode = .none; keepFooter = false; stitch()
        }
    }

    func makeEditSnapshot() -> EditRestoreSnapshot {
        EditRestoreSnapshot(
            images: images, result: result, cachedChain: cachedChain,
            alignmentTopCrop: alignmentTopCrop, alignmentBottomCrop: alignmentBottomCrop,
            topCropFraction: topCropFraction, bottomCropFraction: bottomCropFraction,
            headerMode: headerMode, keepFooter: keepFooter, stitchNotice: stitchNotice
        )
    }

    func restoreEditSnapshot(_ snapshot: EditRestoreSnapshot) {
        cancelInFlightStitch()
        if images.map(\.id) != snapshot.images.map(\.id) { images = snapshot.images }
        alignmentTopCrop = snapshot.alignmentTopCrop; alignmentBottomCrop = snapshot.alignmentBottomCrop
        topCropFraction = snapshot.topCropFraction; bottomCropFraction = snapshot.bottomCropFraction
        headerMode = snapshot.headerMode; keepFooter = snapshot.keepFooter
        result = snapshot.result; cachedChain = snapshot.cachedChain; stitchNotice = snapshot.stitchNotice
        failedSeam = nil; errorMessage = nil; isShowingError = false
    }

    func cancelInFlightStitch() {
        stitchGeneration &+= 1
        isStitching = false
    }

    private func handleStitchOutcome(_ outcome: Result<StitchReport, StitchEngine.StitchError>) {
        switch outcome {
        case .success(let report):
            var finalReport = report
            if let chain = report.resolvedChain {
                let initialTop: Float = headerMode == .full ? 0 : (
                    headerMode == .navBarOnly ? min(alignmentTopCrop, FixedBarDetector.recordingStatusBandFloor) : alignmentTopCrop
                )
                let initialBot: Float = keepFooter ? 0 : alignmentBottomCrop
                if abs(effectiveOutputTopCrop - initialTop) > 1e-4 || abs(effectiveOutputBottomCrop - initialBot) > 1e-4,
                   case .success(let recomposited) = engine.recompositeSync(
                       chain: chain, outputTopFraction: effectiveOutputTopCrop,
                       outputBottomFraction: effectiveOutputBottomCrop, removeScrollIndicator: removeScrollIndicator
                   ) {
                    finalReport = recomposited
                }
            }
            stitchNotice = formatNotice(report: finalReport)
            let ids = Array(Set(images.compactMap(\.assetIdentifier)))
            // Set result before mutating images so StitchEditorView.handleImagesChanged doesn't trigger a redundant re-stitch.
            result = StitchResult(image: finalReport.image, sourceAssetIdentifiers: ids, segmentSpans: finalReport.segmentSpans)
            if finalReport.orderAdjustment != .none,
               finalReport.resolvedOrder.count == images.count,
               Set(finalReport.resolvedOrder).count == images.count {
                images = finalReport.resolvedOrder.map { images[$0] }
            }
            cachedChain = finalReport.resolvedChain ?? report.resolvedChain
        case .failure(let error):
            cachedChain = nil; result = nil
            if case .unsafeSeam(let seam) = error {
                failedSeam = seam; errorMessage = describe(error)
            } else {
                present(error: describe(error))
            }
        }
    }

    // MARK: - Segment Editing & Seam Recovery

    /// Replaces the frame at `index` with a newly picked `PhotosPickerItem` and re-stitches.
    @discardableResult
    func replaceFrame(at index: Int, with item: PhotosPickerItem) async -> Bool {
        guard images.indices.contains(index), !isStitching else { return false }
        do {
            guard let decoded = try await decodePickerItem(item) else {
                present(error: "无法读取所选图片。"); return false
            }
            guard images.indices.contains(index) else { return false }
            images[index] = decoded; stitchNotice = nil
            if images.count >= 2 { stitch() }
            return true
        } catch {
            present(error: "替换图片失败：\(error.localizedDescription)"); return false
        }
    }

    /// Removes the frame at `index` while keeping at least 2 frames, then re-stitches.
    @discardableResult
    func removeFrameInEditor(at index: Int) -> Bool {
        guard images.count > 2, images.indices.contains(index), !isStitching else { return false }
        images.remove(at: index); stitchNotice = nil; stitch()
        return true
    }

    func removeFrameAndRetry(at index: Int) {
        guard images.indices.contains(index), !isStitching else { return }
        images.remove(at: index); refreshAutoCropAndStitchIfReady()
    }

    func trimLeadingFramesAndRetry(from startIndex: Int) {
        guard startIndex > 0, startIndex < images.count, !isStitching else { return }
        images = Array(images[startIndex...]); refreshAutoCropAndStitchIfReady()
    }

    func trimTrailingFramesAndRetry(keepingUpTo endIndex: Int) {
        guard endIndex >= 0, endIndex < images.count - 1, !isStitching else { return }
        images = Array(images[0...endIndex]); refreshAutoCropAndStitchIfReady()
    }

    func swapPairAndRetry() { guard images.count == 2, !isStitching else { return }; images.swapAt(0, 1); refreshAutoCropAndStitchIfReady() }
    func reverseOrder() { guard images.count >= 2, !isStitching else { return }; images.reverse() }
    func reverseAllAndRetry() { guard images.count >= 2, !isStitching else { return }; images.reverse(); refreshAutoCropAndStitchIfReady() }

    // MARK: - Errors

    private func present(error: String) { errorMessage = error; isShowingError = true }
}
