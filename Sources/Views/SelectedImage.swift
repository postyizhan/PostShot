// SPDX-License-Identifier: AGPL-3.0-or-later
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
private extension UIImage {
    func resizedForDecoder(scale: CGFloat) -> UIImage {
        guard scale < 1 else { return self }
        let size = CGSize(width: CGFloat(size.width) * scale, height: CGFloat(size.height) * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: size)) }
    }
}
enum ImageDecoder {
    /// Max thumbnail edge in pixels for the strip.
    static let thumbnailMaxPixel = 200

    static func decode(
        _ data: Data,
        orientation: CGImagePropertyOrientation? = nil
    ) throws -> SelectedImage {
        guard let normalized = try? ImageNormalizer.normalize(
            data: data,
            orientationOverride: orientation.map { Int($0.rawValue) }
        ) else {
            throw ImageLoadError.decodeFailed
        }
        let full = normalized.image
        let thumbSize = thumbnailMaxPixel
        let scale = min(1, CGFloat(thumbSize) / CGFloat(max(full.width, full.height)))
        let thumb = UIImage(cgImage: full).resizedForDecoder(scale: scale)
        return SelectedImage(cgImage: full, thumbnail: thumb)
    }
}
