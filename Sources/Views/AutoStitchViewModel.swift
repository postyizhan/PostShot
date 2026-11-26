// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import Photos

/// Drives the Tailor-style auto-discovery flow: request read access, fetch screenshots, cluster
/// them into sessions, and (on selection) load a session's full-resolution frames into a
/// `StitchViewModel` for the shared review/stitch UI.
@MainActor
final class AutoStitchViewModel: ObservableObject {

    enum DiscoveryState: Equatable {
        case idle
        case loading
        case denied
        case empty           // access granted but no screenshot sessions found
        case loaded([ScreenshotGrouping.ScreenshotSession])
    }

    @Published private(set) var state: DiscoveryState = .idle
    @Published var isPreparingSession = false
    @Published var isShowingError = false
    @Published private(set) var errorMessage: String?

    /// Authorizes, fetches the Screenshots album, and groups it into sessions.
    func discover() async {
        state = .loading
        do {
            let metas = try await ScreenshotLibrary.fetchScreenshotMetas()
            let sessions = ScreenshotGrouping.group(metas)
            state = sessions.isEmpty ? .empty : .loaded(sessions)
        } catch {
            state = .denied
        }
    }

    /// Loads a session's full-resolution frames and returns a model seeded for diagnostic review.
    /// A conservative crop suggestion is visible in the sliders, but stitching never starts until
    /// the user reviews the inputs and taps the stitch button.
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
            let (decoded, suggestion) = try await Task.detached(priority: .userInitiated) {
                let original = try results.map { result -> SelectedImage in
                    guard let data = result.data else { throw ImageLoadError.decodeFailed }
                    return try ImageDecoder.decode(data, orientation: result.orientation)
                }
                let sourceImages = original.map(\.cgImage)
                let suggestion = FixedBarDetector.detectFractions(sourceImages)
                let recoveredOrder = ScreenshotSequenceOrderer.order(
                    images: sourceImages,
                    topCropFraction: suggestion.top,
                    bottomCropFraction: suggestion.bottom
                )
                let ordered = recoveredOrder.map { order in order.map { original[$0] } } ?? original
                return (ordered, suggestion)
            }.value
            let model = StitchViewModel(autoSuggestCrop: true)
            model.load(decodedImages: decoded)
            model.topCropFraction = suggestion.top
            model.bottomCropFraction = suggestion.bottom
            return model
        } catch {
            present(error: "这组截图解码失败，请重试或改用手动选图拼接。")
            return nil
        }
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
