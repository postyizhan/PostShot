// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Photos

/// Loads original screenshot bytes without losing source identity or orientation metadata.
enum ScreenshotImageLoader {
    struct Result {
        let sourceIndex: Int
        let sourceID: String
        let data: Data?
        let orientation: CGImagePropertyOrientation?
    }

    /// Returns exactly one result per requested identifier, preserving order and failures.
    static func loadImageData(for ids: [String]) async -> [Result] {
        var results: [Result] = []
        results.reserveCapacity(ids.count)
        for (index, id) in ids.enumerated() {
            guard let asset = ScreenshotLibrary.asset(for: id),
                  let loaded = await requestData(for: asset) else {
                results.append(Result(sourceIndex: index, sourceID: id, data: nil, orientation: nil))
                continue
            }
            results.append(Result(
                sourceIndex: index,
                sourceID: id,
                data: loaded.data,
                orientation: loaded.orientation
            ))
        }
        return results
    }

    private static func requestData(
        for asset: PHAsset
    ) async -> (data: Data, orientation: CGImagePropertyOrientation)? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.isSynchronous = false
            options.version = .current

            PHImageManager.default().requestImageDataAndOrientation(
                for: asset,
                options: options
            ) { data, _, orientation, _ in
                guard let data else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: (data, orientation))
            }
        }
    }
}
