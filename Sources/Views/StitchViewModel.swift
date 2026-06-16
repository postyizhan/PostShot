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

    // MARK: - Selection

    func clear() {
        pickerItems = []
        images = []
        result = nil
    }

    /// Loads captured frames (Phase 2): decodes full-resolution PNG bytes from the broadcast
    /// bridge into `SelectedImage`s, reusing the exact same decode path and review UI as the
    /// PhotosPicker flow. Frames keep their capture order. Failed frames are skipped, not fatal.
    func load(pngFrames: [Data]) {
        var loaded: [SelectedImage] = []
        for png in pngFrames {
            if let decoded = try? ImageDecoder.decode(png) { loaded.append(decoded) }
        }
        images = loaded
        result = nil
        if loaded.isEmpty && !pngFrames.isEmpty {
            present(error: "无法解码采集到的帧")
        }
    }

    /// Loads full-resolution data for each picked item, preserving picker order (SPEC §8).
    private func loadPickedItems() {
        let items = pickerItems
        guard !items.isEmpty else { return }

        Task {
            var loaded: [SelectedImage] = []
            for item in items {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                    let decoded = try ImageDecoder.decode(data)
                    loaded.append(decoded)
                } catch {
                    // Skip an individual failed item rather than aborting the whole batch.
                    continue
                }
            }
            self.images = loaded
            if loaded.isEmpty {
                self.present(error: "无法加载所选图片")
            }
        }
    }

    // MARK: - Stitching

    func stitch() {
        guard images.count >= 1, !isStitching else { return }
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

    private func describe(_ error: StitchEngine.StitchError) -> String {
        switch error {
        case .noImages:
            return "没有可拼接的图片"
        case .compositeFailed:
            return "图像合成失败,请重试或减少图片数量"
        }
    }
}
