import SwiftUI
import UIKit
import CoreGraphics
import ImageIO

/// An image the user selected for stitching, identified for reordering/deletion in the strip.
struct SelectedImage: Identifiable, Equatable {
    let id = UUID()
    /// Full-resolution decoded image used for stitching.
    let cgImage: CGImage
    /// Small thumbnail for the strip UI.
    let thumbnail: UIImage

    static func == (lhs: SelectedImage, rhs: SelectedImage) -> Bool {
        lhs.id == rhs.id
    }
}

enum ImageLoadError: Error {
    case decodeFailed
}

/// Decodes full-resolution image data into a `CGImage` plus a downscaled thumbnail.
///
/// We decode from the original `Data` (loaded via `loadTransferable(type: Data.self)`),
/// never via a `UIImage` round-trip, to preserve full-resolution sharpness (SPEC §8).
enum ImageDecoder {

    /// Max thumbnail edge in pixels for the strip.
    static let thumbnailMaxPixel = 200

    static func decode(_ data: Data) throws -> SelectedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImageLoadError.decodeFailed
        }
        let fullOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let full = CGImageSourceCreateImageAtIndex(source, 0, fullOptions as CFDictionary) else {
            throw ImageLoadError.decodeFailed
        }

        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixel,
        ]
        let thumbCG = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary)
        let thumbnail = thumbCG.map { UIImage(cgImage: $0) } ?? UIImage(cgImage: full)

        return SelectedImage(cgImage: full, thumbnail: thumbnail)
    }
}
