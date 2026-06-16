// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Photos

/// Loads full-resolution image data for screenshots in a session, for handoff to the stitch
/// backend. Requests original (non-downsampled) data so the long-screenshot stays sharp — the same
/// quality contract as `ImageDecoder` in the PhotosPicker path.
enum ScreenshotImageLoader {

    /// Loads full-resolution PNG/HEIC bytes for each screenshot id, preserving the given order.
    /// Assets that fail to load are skipped (not fatal) so one bad item can't abort a session.
    /// - Returns: image data in the same order as `ids` (minus any that failed).
    static func loadImageData(for ids: [String]) async -> [Data] {
        var result: [Data] = []
        result.reserveCapacity(ids.count)
        for id in ids {
            guard let asset = ScreenshotLibrary.asset(for: id),
                  let data = await requestData(for: asset) else { continue }
            result.append(data)
        }
        return result
    }

    /// Requests original image data for one asset, bridging the callback API to async.
    private static func requestData(for asset: PHAsset) async -> Data? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true   // allow iCloud-stored originals to download
            options.deliveryMode = .highQualityFormat
            options.isSynchronous = false
            options.version = .current

            PHImageManager.default().requestImageDataAndOrientation(
                for: asset, options: options
            ) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
    }
}
