// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import CoreGraphics
import UIKit
import ImageIO
import UniformTypeIdentifiers

/// Exports a stitched `CGImage` (the output of `StitchEngine`) to encoded image `Data`,
/// and writes that data to a temporary file for sharing.
///
/// The SwiftUI share sheet is built in the UI layer; this type only provides the
/// `Data`/`URL` plumbing it consumes.
enum ImageExporter {

    /// Supported export formats.
    enum ImageFormat {
        case png
        case jpeg(quality: CGFloat)
        /// HEIC via ImageIO; throws `encodingFailed` when the HEIC encoder is unavailable.
        case heic(quality: CGFloat)

        /// Human-readable file extension for this format.
        var fileExtension: String {
            switch self {
            case .png:  return "png"
            case .jpeg: return "jpg"
            case .heic: return "heic"
            }
        }
    }

    enum ImageExporterError: Error {
        /// The `CGImage` could not be encoded into the requested format.
        case encodingFailed
        /// The encoded data could not be written to a temporary file.
        case fileWriteFailed(Error)
    }

    /// Encodes `image` into `Data` using the requested `format`.
    ///
    /// Throws `ImageExporterError.encodingFailed` when the underlying encoder returns nil
    /// (e.g. an unsupported pixel layout or unavailable codec such as HEIC on simulators).
    static func export(_ image: CGImage, as format: ImageFormat) throws -> Data {
        switch format {
        case .png:               return try exportPNG(image)
        case .jpeg(let quality): return try exportJPEG(image, quality: quality)
        case .heic(let quality): return try exportHEIC(image, quality: quality)
        }
    }

    /// Writes `data` to a uniquely named file in the system temporary directory and
    /// returns its URL. `fileExtension` is used verbatim (e.g. "png", "jpg").
    static func writeTemporaryFile(_ data: Data, fileExtension: String) throws -> URL {
        let fileName = "PostShot-\(UUID().uuidString).\(fileExtension)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ImageExporterError.fileWriteFailed(error)
        }
        return url
    }

    // MARK: - Private encoders

    private static func exportPNG(_ image: CGImage) throws -> Data {
        guard let data = UIImage(cgImage: image).pngData() else {
            throw ImageExporterError.encodingFailed
        }
        return data
    }

    private static func exportJPEG(_ image: CGImage, quality: CGFloat) throws -> Data {
        let clamped = max(0, min(quality, 1))
        guard let data = UIImage(cgImage: image).jpegData(compressionQuality: clamped) else {
            throw ImageExporterError.encodingFailed
        }
        return data
    }

    private static func exportHEIC(_ image: CGImage, quality: CGFloat) throws -> Data {
        let mutable = NSMutableData()
        let utType: CFString = UTType.heic.identifier as CFString
        guard let dest = CGImageDestinationCreateWithData(mutable, utType, 1, nil) else {
            throw ImageExporterError.encodingFailed
        }
        let clamped = max(0.0, min(Double(quality), 1.0))
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: clamped]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ImageExporterError.encodingFailed
        }
        return mutable as Data
    }
}
