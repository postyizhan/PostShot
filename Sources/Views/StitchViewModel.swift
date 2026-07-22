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
    @Published var images: [SelectedImage] = []
    @Published var isStitching = false
    @Published var progress: Double = 0
    @Published var result: StitchResult?

    @Published var topCropFraction: Float = 0
    @Published var bottomCropFraction: Float = 0

    @Published var isShowingError = false
    @Published private(set) var errorMessage: String?

    private let engine = StitchEngine()
    private var loadTask: Task<Void, Never>?

    // MARK: - Selection

    func clear() {
        loadTask?.cancel()
        pickerItems = []
        images = []
        result = nil
    }

    /// Seeds already-decoded canonical images, preserving their validated order.
    func load(decodedImages: [SelectedImage]) {
        images = decodedImages
        result = nil
    }

    /// Loads captured frames through the shared canonical decoder while preserving adjacency.
    /// Any failed frame blocks the batch instead of silently joining non-adjacent frames.
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
        result = nil
        guard failedIndices.isEmpty else {
            images = []
            present(error: failedLoadMessage(prefix: "采集帧", indices: failedIndices))
            return
        }
        images = loaded
    }

    /// Produces a visible crop suggestion for review. It never starts stitching automatically.
    func suggestFixedBarCrop() {
        guard images.count >= 2 else { return }
        let suggestion = FixedBarDetector.detectFractions(images.map(\.cgImage))
        topCropFraction = suggestion.top
        bottomCropFraction = suggestion.bottom
    }

    /// Loads full-resolution data for each picked item, preserving picker order (SPEC §8).
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
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        failedIndices.append(index)
                        continue
                    }
                    loaded.append(try ImageDecoder.decode(data))
                } catch is CancellationError {
                    return
                } catch {
                    failedIndices.append(index)
                }
            }
            guard !Task.isCancelled, items == self.pickerItems else { return }
            self.result = nil
            guard failedIndices.isEmpty else {
                self.images = []
                self.present(error: self.failedLoadMessage(prefix: "所选图片", indices: failedIndices))
                return
            }
            self.images = loaded
        }
    }

    // MARK: - Stitching

    func stitch() {
        guard images.count >= 1, !isStitching else { return }
        result = nil
        isStitching = true
        progress = 0

        var options = StitchEngine.Options()
        options.topCropFraction = topCropFraction
        options.bottomCropFraction = bottomCropFraction
        let cgImages = images.map { $0.cgImage }

        engine.stitch(images: cgImages, options: options) { [weak self] value in
            Task { @MainActor in self?.progress = value }
        } completion: { [weak self] outcome in
            Task { @MainActor in
                guard let self else { return }
                self.isStitching = false
                switch outcome {
                case .success(let image):
                    self.result = StitchResult(image: image)
                case .failure(let error):
                    self.result = nil
                    self.present(error: self.describe(error))
                }
            }
        }
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
            return "第\(seam.topIndex + 1)张与第\(seam.bottomIndex + 1)张证据不足，已停止拼接"
        case .compositeFailed:
            return "图像合成失败，请重试或减少图片数量"
        }
    }
}
