// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import Photos

/// Drives the Tailor-style auto-discovery flow: request read access, fetch screenshots, cluster
/// them into sessions, and load a session's full-resolution frames into `StitchViewModel`.
@MainActor
final class AutoStitchViewModel: ObservableObject {

    enum DiscoveryState: Equatable {
        case idle
        case loading
        case denied
        case empty
        case loaded([ScreenshotGrouping.ScreenshotSession])
    }

    @Published private(set) var state: DiscoveryState = .idle
    @Published var isPreparingSession = false
    @Published var isShowingError = false
    @Published private(set) var errorMessage: String?

    func discover() async {
        if case .loaded = state { } else { state = .loading }
        do {
            let metas = try await ScreenshotLibrary.fetchScreenshotMetas()
            let sessions = ScreenshotGrouping.group(metas)
            state = sessions.isEmpty ? .empty : .loaded(sessions)
        } catch {
            state = .denied
        }
    }

    /// Loads a session's full-resolution frames and returns a model seeded for review and stitch.
    func makeStitchModel(for session: ScreenshotGrouping.ScreenshotSession) async -> StitchViewModel? {
        isPreparingSession = true
        defer { isPreparingSession = false }

        let ids = session.items.map(\.id)
        let results = await ScreenshotImageLoader.loadImageData(for: ids)
        let failures = results.filter { $0.data == nil }
        guard failures.isEmpty else {
            presentLoadFailure(indices: failures.map(\.sourceIndex))
            return nil
        }

        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                try Self.prepareFrames(from: results)
            }.value
            let model = StitchViewModel(autoSuggestCrop: true)
            model.load(decodedImages: prepared.0)
            model.applyDetectedFixedBarCrop(top: prepared.1.top, bottom: prepared.1.bottom)
            model.notePreExcluded(indices: prepared.2)
            return model
        } catch {
            present(error: "这组截图解码失败，请重试或改用手动选图拼接。")
            return nil
        }
    }

    nonisolated private static func prepareFrames(
        from results: [ScreenshotImageLoader.Result]
    ) throws -> ([SelectedImage], (top: Float, bottom: Float), [Int]) {
        let original = try results.map { result -> SelectedImage in
            guard let data = result.data else { throw ImageLoadError.decodeFailed }
            return try ImageDecoder.decode(
                data,
                orientation: result.orientation,
                assetIdentifier: result.sourceID
            )
        }
        let sourceImages = original.map(\.cgImage)
        let initialCrop = FixedBarDetector.detectFractions(sourceImages)
        let recoveredOrder = ScreenshotSequenceOrderer.order(
            images: sourceImages,
            topCropFraction: initialCrop.top,
            bottomCropFraction: initialCrop.bottom
        )
        let ordered = recoveredOrder.map { order in order.map { original[$0] } } ?? original
        let excluded: [Int]
        if let order = recoveredOrder, order.count < original.count {
            let kept = Set(order)
            excluded = original.indices.filter { !kept.contains($0) }
        } else {
            excluded = []
        }
        let finalCrop = excluded.isEmpty
            ? initialCrop
            : FixedBarDetector.detectFractions(ordered.map(\.cgImage))
        return (ordered, finalCrop, excluded)
    }

    private func presentLoadFailure(indices: [Int]) {
        let positions = indices.map { String($0 + 1) }.joined(separator: "、")
        present(error: "第 \(positions) 张截图加载失败。为避免改变相邻关系，未开始拼接。")
    }

    private func present(error: String) {
        errorMessage = error
        isShowingError = true
    }
}
