import Foundation
import CoreGraphics
import UIKit
import Photos

/// Saves a stitched `CGImage` (the output of `StitchEngine`) to the user's photo album.
///
/// Uses add-only Photos authorization, which only requires `NSPhotoLibraryAddUsageDescription`
/// in Info.plist. The image is encoded to PNG and added as a `.photo` resource so the original
/// long-screenshot pixels are preserved without recompression.
enum PhotoSaver {

    enum PhotoSaverError: Error {
        /// The user denied (or restricted) add-only access to the photo library.
        case authorizationDenied
        /// The `CGImage` could not be encoded to PNG data.
        case encodingFailed
        /// The Photos library reported a failure while performing the save.
        case saveFailed(Error)
    }

    /// Saves `image` to the photo album as a PNG asset.
    ///
    /// Requests add-only authorization first, then performs the asset creation. Throws
    /// `PhotoSaverError` on any failure — errors are surfaced, never swallowed.
    static func save(_ image: CGImage) async throws {
        let status = await requestAddOnlyAuthorization()
        guard status == .authorized || status == .limited else {
            throw PhotoSaverError.authorizationDenied
        }

        guard let pngData = encodePNG(image) else {
            throw PhotoSaverError.encodingFailed
        }

        try await performSave(pngData)
    }

    // MARK: - Authorization

    /// Wraps the callback-based authorization request in an async continuation.
    private static func requestAddOnlyAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }

    // MARK: - Encoding

    /// Renders the `CGImage` to PNG data via UIKit.
    private static func encodePNG(_ image: CGImage) -> Data? {
        UIImage(cgImage: image).pngData()
    }

    // MARK: - Persistence

    /// Performs the Photos library change request, bridging its completion handler to async.
    private static func performSave(_ pngData: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                request.addResource(with: .photo, data: pngData, options: options)
            } completionHandler: { success, error in
                if success {
                    continuation.resume(returning: ())
                } else if let error {
                    continuation.resume(throwing: PhotoSaverError.saveFailed(error))
                } else {
                    continuation.resume(throwing: PhotoSaverError.encodingFailed)
                }
            }
        }
    }
}
