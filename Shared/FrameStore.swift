// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Stores and retrieves captured frames in the shared App Group container.
///
/// The broadcast extension writes frames (memory-safe: encode one, write, release — never
/// accumulate); the main app reads them back after recording to feed the stitching backend.
/// Frames are sequentially numbered so ordering is preserved across the process boundary.
enum FrameStore {

    enum FrameStoreError: Error {
        case containerUnavailable
        case encodingFailed
        case writeFailed(Error)
    }

    /// Removes any frames from a previous session and recreates the frames directory.
    /// Called by the extension at broadcast start so each recording is clean.
    static func reset() throws {
        guard let dir = AppGroup.framesDirectory else { throw FrameStoreError.containerUnavailable }
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path) {
            try? fm.removeItem(at: dir)
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// File URL for the frame at `index` (zero-padded so lexical sort == capture order).
    private static func frameURL(index: Int) -> URL? {
        guard let dir = AppGroup.framesDirectory else { return nil }
        let name = String(format: "frame_%05d.png", index)
        return dir.appendingPathComponent(name)
    }

    /// Encodes `image` to PNG and writes it as frame `index`. Caller must release `image`
    /// immediately after — this method does not retain it.
    static func write(_ image: CGImage, index: Int) throws {
        guard let url = frameURL(index: index) else { throw FrameStoreError.containerUnavailable }
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { throw FrameStoreError.encodingFailed }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw FrameStoreError.encodingFailed }
    }

    /// Returns all captured frame file URLs in capture order.
    static func frameURLs() -> [URL] {
        guard let dir = AppGroup.framesDirectory else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        )) ?? []
        return urls
            .filter { $0.pathExtension == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Number of frames currently in the shared container.
    static func frameCount() -> Int {
        frameURLs().count
    }

    /// Loads all captured frames as decoded `CGImage`s, in capture order (main app side).
    static func loadFrames() -> [CGImage] {
        frameURLs().compactMap { url in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
    }
}
