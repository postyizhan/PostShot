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

    /// Loads a session's full-resolution frames and returns a `StitchViewModel` seeded with them,
    /// then kicks off fully-automatic fixed-bar detection + stitch. The returned model drives
    /// `StitchReviewView`, whose preview cover auto-presents once the stitch completes; the user can
    /// dismiss it to tweak crop/order and re-stitch. Returns nil if no frames could be loaded.
    func makeStitchModel(for session: ScreenshotGrouping.ScreenshotSession) async -> StitchViewModel? {
        isPreparingSession = true
        defer { isPreparingSession = false }

        let ids = session.items.map(\.id)
        let data = await ScreenshotImageLoader.loadImageData(for: ids)
        guard !data.isEmpty else { return nil }

        let model = StitchViewModel()
        model.load(pngFrames: data)
        model.autoStitch()
        return model
    }
}
