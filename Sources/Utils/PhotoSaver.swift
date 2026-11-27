// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import CoreGraphics
import UIKit
import Photos

/// Saves a stitched `CGImage` to the user's photo album, and optionally moves source
/// originals into the system "Recently Deleted" bin.
enum PhotoSaver {

    enum PhotoSaverError: Error {
        case authorizationDenied
        case encodingFailed
        case saveFailed(Error)
        /// The user cancelled or denied the system delete-confirmation dialog.
        case deleteCancelled
    }

    // MARK: - Save

    /// Backward-compatible overload: saves `image` as PNG.
    static func save(_ image: CGImage) async throws {
        try await save(image, format: .png)
    }

    /// Saves `image` to the photo album in the specified `format`.
    static func save(_ image: CGImage, format: ImageExporter.ImageFormat = .png) async throws {
        let status = await requestAddOnlyAuthorization()
        guard status == .authorized || status == .limited else {
            throw PhotoSaverError.authorizationDenied
        }
        let data = try encodeImage(image, format: format)
        try await performSave(data)
    }

    // MARK: - Delete originals

    /// Requests that iOS move the specified photo assets to "Recently Deleted".
    ///
    /// iOS shows its own confirmation alert; if the user cancels, throws `deleteCancelled`.
    /// - Returns: the number of assets successfully requested for deletion.
    static func deleteOriginalAssets(identifiers: [String]) async throws -> Int {
        let filtered = identifiers.filter { !$0.isEmpty }
        guard !filtered.isEmpty else { return 0 }
        let status = await requestReadWriteAuthorization()
        guard status == .authorized || status == .limited else {
            throw PhotoSaverError.authorizationDenied
        }
        return try await performDelete(identifiers: filtered)
    }

    // MARK: - Authorization

    private static func requestAddOnlyAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }

    private static func requestReadWriteAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    // MARK: - Encoding

    private static func encodeImage(_ image: CGImage, format: ImageExporter.ImageFormat) throws -> Data {
        do {
            return try ImageExporter.export(image, as: format)
        } catch {
            throw PhotoSaverError.encodingFailed
        }
    }

    // MARK: - Persistence

    private static func performSave(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                request.addResource(with: .photo, data: data, options: options)
            } completionHandler: { success, error in
                if success {
                    continuation.resume(returning: ())
                } else if let error {
                    continuation.resume(throwing: PhotoSaverError.saveFailed(error))
                } else {
                    let fallback = NSError(domain: "com.postshot.photosaver", code: -1)
                    continuation.resume(throwing: PhotoSaverError.saveFailed(fallback))
                }
            }
        }
    }

    private static func performDelete(identifiers: [String]) async throws -> Int {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        guard assets.count > 0 else { return 0 }
        return try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            } completionHandler: { success, error in
                if success {
                    continuation.resume(returning: assets.count)
                } else if let error {
                    let nsErr = error as NSError
                    // PHPhotosErrorDomain code 3072 = user cancelled
                    if nsErr.domain == "PHPhotosErrorDomain" || nsErr.code == 3072 {
                        continuation.resume(throwing: PhotoSaverError.deleteCancelled)
                    } else {
                        continuation.resume(throwing: PhotoSaverError.saveFailed(error))
                    }
                } else {
                    continuation.resume(throwing: PhotoSaverError.deleteCancelled)
                }
            }
        }
    }
}
