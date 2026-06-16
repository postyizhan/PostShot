// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Photos

/// Reads the system "Screenshots" smart album and maps assets into `ScreenshotMeta` for grouping.
///
/// Read access (not add-only) is required, so Info.plist must carry `NSPhotoLibraryUsageDescription`.
/// Returns lightweight metadata only — full-resolution pixels are loaded lazily per-session by
/// `ScreenshotImageLoader`, so discovery stays cheap even with a large library.
enum ScreenshotLibrary {

    enum LibraryError: Error {
        case authorizationDenied
    }

    /// Requests read authorization. Returns the resolved status (authorized/limited are usable).
    static func requestAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// Fetches screenshot metadata (most-recent first), after ensuring read access.
    /// - Throws: `LibraryError.authorizationDenied` if the user denied/restricted access.
    static func fetchScreenshotMetas() async throws -> [ScreenshotGrouping.ScreenshotMeta] {
        let status = await requestAuthorization()
        guard status == .authorized || status == .limited else {
            throw LibraryError.authorizationDenied
        }
        return fetchMetas()
    }

    /// Synchronous fetch from the Screenshots smart album → `ScreenshotMeta` array.
    private static func fetchMetas() -> [ScreenshotGrouping.ScreenshotMeta] {
        let collections = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .smartAlbumScreenshots,
            options: nil
        )
        guard let album = collections.firstObject else { return [] }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(in: album, options: options)

        var metas: [ScreenshotGrouping.ScreenshotMeta] = []
        metas.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            metas.append(ScreenshotGrouping.ScreenshotMeta(
                id: asset.localIdentifier,
                creationDate: asset.creationDate ?? .distantPast,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight
            ))
        }
        return metas
    }

    /// Resolves a `ScreenshotMeta.id` (PHAsset localIdentifier) back to its `PHAsset`.
    static func asset(for id: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }
}
