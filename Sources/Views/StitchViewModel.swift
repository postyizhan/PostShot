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
        self.image = image
        self.sourceAssetIdentifiers = sourceAssetIdentifiers
        self.segmentSpans = segmentSpans
    }
}

/// Owns selection, loading, auto-crop detection, backfill source, and stitching state.
@MainActor
final class StitchViewModel: ObservableObject {
    @Published var pickerItems: [PhotosPickerItem] = [] {
        didSet { loadPickedItems() }
    }
    @Published var images: [SelectedImage] = [] {
        didSet {
            stitchGeneration &+= 1
            failedSeam = nil
        }
    }
    @Published var isStitching = false
    @Published var progress: Double = 0
    @Published var result: StitchResult?

    @Published var topCropFraction: Float = 0
    @Published var bottomCropFraction: Float = 0
    @Published var headerMode: HeaderKeepMode = .none
    @Published var keepFooter: Bool = false
    @Published var removeScrollIndicator: Bool = true

    @Published var isShowingError = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var failedSeam: StitchSeam?
    @Published private(set) var stitchNotice: String?

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
        loadTask?.cancel()
        cropTask?.cancel()
        stitchGeneration &+= 1
        isStitching = false
        pickerItems = []
        images = []
        result = nil
        failedSeam = nil
        errorMessage = nil
        stitchNotice = nil
        isShowingError = false
        lastSuggestedCrop = nil
        recordingStore = nil
    }

    /// Seeds already-decoded canonical images, preserving their validated order.
    func load(decodedImages: [SelectedImage]) {
        isRecordingSource = false
        recordingStore = nil
        stitchNotice = nil
        images = decodedImages
        result = nil
        errorMessage = nil
        isShowingError = false
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
                    item.poolIndex = poolIdx
                    loaded.append(item)
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

    private func applySuggestedCrop(_ suggestion: (top: Float, bottom: Float)) {
        topCropFraction = suggestion.top; bottomCropFraction = suggestion.bottom; lastSuggestedCrop = suggestion
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
        guard !items.isEmpty else {
            images = []
            stitchNotice = nil
            return
        }

        loadTask = Task {
            var loaded: [SelectedImage] = []
            var failedIndices: [Int] = []
            for (index, item) in items.enumerated() {
                guard !Task.isCancelled else { return }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        failedIndices.append(index)
                        continue
                    }
                    let assetID = item.itemIdentifier
                    let decoded = try await Task.detached(priority: .userInitiated) {
                        try ImageDecoder.decode(data, assetIdentifier: assetID)
                    }.value
                    loaded.append(decoded)
                } catch is CancellationError {
                    return
                } catch {
                    failedIndices.append(index)
                }
            }
            guard !Task.isCancelled, items == self.pickerItems else { return }
            self.isRecordingSource = false
            self.recordingStore = nil
            self.stitchNotice = nil
            self.applyLoadedFrames(loaded, failedIndices: failedIndices, prefix: "所选图片")
            if self.autoSuggestCrop, failedIndices.isEmpty, loaded.count >= 2 {
                await self.suggestFixedBarCropAsync()
            }
        }
    }

    // MARK: - Stitching

    func stitch() {
        guard images.count >= 2, !isStitching else { return }
        stitchGeneration &+= 1
        let expectedGen = stitchGeneration
        result = nil
        failedSeam = nil
        errorMessage = nil
        isShowingError = false
        isStitching = true
        progress = 0

        var options = StitchEngine.Options()
        options.topCropFraction = topCropFraction
        options.bottomCropFraction = bottomCropFraction
        options.headerMode = headerMode
        options.keepFooter = keepFooter
        options.removeScrollIndicator = removeScrollIndicator
        if let store = recordingStore {
            let indices = images.compactMap(\.poolIndex)
            if indices.count == images.count {
                options.backfill = FrameBackfillSource(
                    poolIndices: indices,
                    loadFrame: { store.loadCGImage(at: $0) }
                )
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
                self.isStitching = false
                self.handleStitchOutcome(outcome)
            }
        }
    }

    private func handleStitchOutcome(_ outcome: Result<StitchReport, StitchEngine.StitchError>) {
        switch outcome {
        case .success(let report):
            stitchNotice = formatNotice(report: report)
            let ids = Array(Set(images.compactMap(\.assetIdentifier)))
            result = StitchResult(
                image: report.image,
                sourceAssetIdentifiers: ids,
                segmentSpans: report.segmentSpans
            )
        case .failure(let error):
            result = nil
            if case .unsafeSeam(let seam) = error {
                failedSeam = seam
                errorMessage = describe(error)
            } else {
                present(error: describe(error))
            }
        }
    }

    private func formatNotice(report: StitchReport) -> String? {
        var parts: [String] = []
        if !report.skippedIndices.isEmpty {
            let labels = report.skippedIndices.map { String($0 + 1) }.joined(separator: "、")
            parts.append("已自动跳过第 \(labels) 张不衔接画面")
        }
        if report.backfilledCount > 0 {
            parts.append("从录制帧池自动补齐 \(report.backfilledCount) 帧")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "，")
    }

    // MARK: - Segment Editing & Seam Recovery

    /// Replaces the frame at `index` with a newly picked `PhotosPickerItem` and re-stitches.
    @discardableResult
    func replaceFrame(at index: Int, with item: PhotosPickerItem) async -> Bool {
        guard images.indices.contains(index), !isStitching else { return false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                present(error: "无法读取所选图片。")
                return false
            }
            let assetID = item.itemIdentifier
            let decoded = try await Task.detached(priority: .userInitiated) {
                try ImageDecoder.decode(data, assetIdentifier: assetID)
            }.value
            guard images.indices.contains(index) else { return false }
            images[index] = decoded
            stitchNotice = nil
            if images.count >= 2 { stitch() }
            return true
        } catch {
            present(error: "替换图片失败：\(error.localizedDescription)")
            return false
        }
    }

    /// Removes the frame at `index` while keeping at least 2 frames, then re-stitches.
    @discardableResult
    func removeFrameInEditor(at index: Int) -> Bool {
        guard images.count > 2, images.indices.contains(index), !isStitching else { return false }
        images.remove(at: index)
        stitchNotice = nil
        stitch()
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

    func swapPairAndRetry() {
        guard images.count == 2, !isStitching else { return }
        images.swapAt(0, 1); refreshAutoCropAndStitchIfReady()
    }

    // MARK: - Errors

    private func present(error: String) { errorMessage = error; isShowingError = true }

    private func failedLoadMessage(prefix: String, indices: [Int]) -> String {
        let labels = indices.map { String($0 + 1) }.joined(separator: "、")
        return "第 \(labels) 张\(prefix)解码失败。为避免改变相邻关系，已取消本次加载。"
    }

    private func describe(_ error: StitchEngine.StitchError) -> String {
        switch error {
        case .noImages: return "请至少选择 2 张图片。"
        case .invalidInput(let profile):
            if let first = profile.diagnostics.first {
                let idx = first.sourceIndex + 1
                switch first.reason {
                case .empty, .nonPositiveDimensions, .impossiblePixelCount:
                    return "第\(idx)张图片尺寸无效（或裁剪比例过大），无法拼接。"
                case .dimensionMismatch:
                    return "第\(idx)张图片尺寸与首张不一致（\(first.actual) vs \(profile.canonicalSize)），无法安全拼接。"
                }
            }
            return "输入图片校验未通过，无法拼接。"
        case .unsafeSeam(let seam):
            let a = seam.topIndex + 1, b = seam.bottomIndex + 1
            if seam.result.status == .ambiguous {
                return "第\(a)张与第\(b)张存在多处相似内容，自动匹配不确定；可删除异常帧或调整裁剪后重试。"
            }
            return "第\(a)张与第\(b)张未找到可靠重叠区域；可能滚动跨度过大、顺序颠倒或混入无关画面。"
        case .compositeFailed(let underlying):
            return "合成图像失败：\(underlying.localizedDescription)"
        }
    }
}
