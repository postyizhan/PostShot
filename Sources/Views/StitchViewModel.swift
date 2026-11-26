// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import PhotosUI
import CoreGraphics

/// Wraps a stitched `CGImage` so it can drive a SwiftUI `fullScreenCover(item:)`.
struct StitchResult: Identifiable {
    let id = UUID()
    let image: CGImage
}

/// Owns selection, loading, and stitching state for `ContentView`.
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

    @Published var isShowingError = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var failedSeam: StitchSeam?

    private let engine = StitchEngine()
    private let autoSuggestCrop: Bool
    private var lastSuggestedCrop: (top: Float, bottom: Float)?
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
        isShowingError = false
        lastSuggestedCrop = nil
    }

    /// Seeds already-decoded canonical images, preserving their validated order.
    func load(decodedImages: [SelectedImage]) {
        images = decodedImages
        result = nil
        errorMessage = nil
        isShowingError = false
    }

    /// Loads captured frames off the main actor while preserving adjacency.
    func loadAsync(pngFrames: [Data]) async {
        let outcome = await Task.detached(priority: .userInitiated) {
            var loaded: [SelectedImage] = []
            var failedIndices: [Int] = []
            for (index, png) in pngFrames.enumerated() {
                do {
                    loaded.append(try ImageDecoder.decode(png))
                } catch {
                    failedIndices.append(index)
                }
            }
            return (loaded, failedIndices)
        }.value
        applyLoadedFrames(outcome.0, failedIndices: outcome.1, prefix: "采集帧")
    }

    /// Synchronous convenience wrapper for tests or small pre-loaded batches.
    func load(pngFrames: [Data]) {
        var loaded: [SelectedImage] = []
        var failedIndices: [Int] = []
        for (index, png) in pngFrames.enumerated() {
            do {
                loaded.append(try ImageDecoder.decode(png))
            } catch {
                failedIndices.append(index)
            }
        }
        applyLoadedFrames(loaded, failedIndices: failedIndices, prefix: "采集帧")
    }

    private func applyLoadedFrames(_ loaded: [SelectedImage], failedIndices: [Int], prefix: String) {
        result = nil
        guard failedIndices.isEmpty else {
            images = []
            present(error: failedLoadMessage(prefix: prefix, indices: failedIndices))
            return
        }
        errorMessage = nil
        isShowingError = false
        images = loaded
    }

    /// Produces a visible crop suggestion synchronously.
    func suggestFixedBarCrop() {
        guard images.count >= 2 else { return }
        let suggestion = FixedBarDetector.detectFractions(images.map(\.cgImage))
        applySuggestedCrop(suggestion)
    }

    /// Computes fixed-bar crop suggestion off the main thread so large batches never hitch UI.
    func suggestFixedBarCropAsync() async {
        guard images.count >= 2 else { return }
        let expectedGen = stitchGeneration
        let cgImages = images.map(\.cgImage)
        let suggestion = await Task.detached(priority: .userInitiated) {
            FixedBarDetector.detectFractions(cgImages)
        }.value
        guard stitchGeneration == expectedGen else { return }
        applySuggestedCrop(suggestion)
    }

    private func applySuggestedCrop(_ suggestion: (top: Float, bottom: Float)) {
        topCropFraction = suggestion.top
        bottomCropFraction = suggestion.bottom
        lastSuggestedCrop = suggestion
    }

    private func refreshAutoCropAndStitchIfReady() {
        guard images.count >= 2 else { return }
        let shouldRefresh: Bool
        if autoSuggestCrop {
            if let last = lastSuggestedCrop {
                shouldRefresh = abs(topCropFraction - last.top) < 1e-4
                    && abs(bottomCropFraction - last.bottom) < 1e-4
            } else {
                shouldRefresh = true
            }
        } else {
            shouldRefresh = false
        }
        cropTask?.cancel()
        cropTask = Task {
            if shouldRefresh {
                await suggestFixedBarCropAsync()
            }
            guard !Task.isCancelled, images.count >= 2 else { return }
            stitch()
        }
    }

    /// Loads full-resolution data for each picked item, preserving picker order.
    private func loadPickedItems() {
        loadTask?.cancel()
        let items = pickerItems
        guard !items.isEmpty else {
            images = []
            return
        }

        loadTask = Task {
            var loaded: [SelectedImage] = []
            var failedIndices: [Int] = []
            for (index, item) in items.enumerated() {
                guard !Task.isCancelled else { return }
                do {
                    let rawData = try await item.loadTransferable(type: Data.self)
                    guard let data = rawData else {
                        failedIndices.append(index)
                        continue
                    }
                    let decoded = try await Task.detached(priority: .userInitiated) {
                        try ImageDecoder.decode(data)
                    }.value
                    loaded.append(decoded)
                } catch is CancellationError {
                    return
                } catch {
                    failedIndices.append(index)
                }
            }
            guard !Task.isCancelled, items == self.pickerItems else { return }
            self.applyLoadedFrames(loaded, failedIndices: failedIndices, prefix: "所选图片")
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
        let cgImages = images.map { $0.cgImage }

        engine.stitch(images: cgImages, options: options) { [weak self] value in
            Task { @MainActor in
                guard let self, self.stitchGeneration == expectedGen else { return }
                self.progress = value
            }
        } completion: { [weak self] outcome in
            Task { @MainActor in
                guard let self, self.stitchGeneration == expectedGen else { return }
                self.isStitching = false
                switch outcome {
                case .success(let image):
                    self.result = StitchResult(image: image)
                case .failure(let error):
                    self.result = nil
                    if case .unsafeSeam(let seam) = error {
                        self.failedSeam = seam
                        self.errorMessage = self.describe(error)
                    } else {
                        self.present(error: self.describe(error))
                    }
                }
            }
        }
    }

    // MARK: - Seam Recovery

    func removeFrameAndRetry(at index: Int) {
        guard images.indices.contains(index), !isStitching else { return }
        images.remove(at: index)
        refreshAutoCropAndStitchIfReady()
    }

    func trimLeadingFramesAndRetry(from startIndex: Int) {
        guard startIndex > 0, startIndex < images.count, !isStitching else { return }
        images = Array(images[startIndex...])
        refreshAutoCropAndStitchIfReady()
    }

    func trimTrailingFramesAndRetry(keepingUpTo endIndex: Int) {
        guard endIndex >= 0, endIndex < images.count - 1, !isStitching else { return }
        images = Array(images[0...endIndex])
        refreshAutoCropAndStitchIfReady()
    }

    func swapPairAndRetry() {
        guard images.count == 2, !isStitching else { return }
        images.swapAt(0, 1)
        refreshAutoCropAndStitchIfReady()
    }

    // MARK: - Errors

    private func present(error message: String) {
        errorMessage = message
        isShowingError = true
    }

    private func failedLoadMessage(prefix: String, indices: [Int]) -> String {
        let positions = indices.map { String($0 + 1) }.joined(separator: "、")
        return "\(prefix)第 \(positions) 项加载失败。为避免改变帧相邻关系，已停止本次拼接。"
    }

    private func describe(_ error: StitchEngine.StitchError) -> String {
        switch error {
        case .noImages:
            return "没有可拼接的图片"
        case .invalidInput(let profile):
            let details = profile.diagnostics.map { "第\($0.sourceIndex + 1)张 \($0.actual)" }.joined(separator: "、")
            return "图片尺寸不一致：\(details)"
        case .unsafeSeam(let seam):
            let top = seam.topIndex + 1
            let bottom = seam.bottomIndex + 1
            if seam.result.status == .ambiguous {
                return "第\(top)张与第\(bottom)张存在多处相似内容，无法唯一对齐，已停止拼接"
            }
            return "第\(top)张与第\(bottom)张缺少足够重叠（可能混入切换过渡帧或滚动过快），已停止拼接"
        case .compositeFailed:
            return "图像合成失败，请重试或减少图片数量"
        }
    }
}
