// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import CoreGraphics
import UIKit

/// Exports a stitched `CGImage` (the output of `StitchEngine`) to encoded image `Data`,
/// and writes that data to a temporary file for sharing.
///
/// The SwiftUI share sheet is built in the UI layer; this type only provides the
/// `Data`/`URL` plumbing it consumes.
enum ImageExporter {

    /// Supported export formats. JPEG carries a 0...1 compression quality.
    enum ImageFormat {
        case png
        case jpeg(quality: CGFloat)
    }

    enum ImageExporterError: Error {
        /// The `CGImage` could not be encoded into the requested format.
        case encodingFailed
        /// The encoded data could not be written to a temporary file.
        case fileWriteFailed(Error)
    }

    /// Encodes `image` into `Data` using the requested `format`.
    ///
    /// Throws `ImageExporterError.encodingFailed` when the underlying UIKit encoder
    /// returns nil (e.g. an unsupported pixel layout).
    static func export(_ image: CGImage, as format: ImageFormat) throws -> Data {
        let uiImage = UIImage(cgImage: image)
        let data: Data?
        switch format {
        case .png:
            data = uiImage.pngData()
        case .jpeg(let quality):
            let clampedQuality = max(0, min(quality, 1))
            data = uiImage.jpegData(compressionQuality: clampedQuality)
        }

        guard let encoded = data else {
            throw ImageExporterError.encodingFailed
        }
        return encoded
    }

    /// Writes `data` to a uniquely named file in the system temporary directory and
    /// returns its URL. `fileExtension` is used verbatim (e.g. "png", "jpg").
    ///
    /// Throws `ImageExporterError.fileWriteFailed` if the write fails.
    static func writeTemporaryFile(_ data: Data, fileExtension: String) throws -> URL {
        let fileName = "LongShot-\(UUID().uuidString).\(fileExtension)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ImageExporterError.fileWriteFailed(error)
        }
        return url
    }
}
