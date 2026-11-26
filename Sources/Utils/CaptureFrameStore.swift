// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreGraphics
import Foundation
import ImageIO
import UIKit

/// Disk-backed pool of dense screen-recording frames stored in the host app's `temporaryDirectory`.
///
/// Keeps full-resolution payloads out of heap RAM while retaining tiny 64×64 grayscale signatures
/// in memory so primary sparse keyframes can be chosen immediately and intermediate frames can be
/// loaded on demand whenever `StitchEngine` needs to bridge a fast-scroll gap or trailing outlier.
final class CaptureFrameStore: @unchecked Sendable {

    struct Entry {
        let index: Int
        let fileURL: URL
        let signature: [Float]
    }

    private let lock = NSLock()
    private var directoryURL: URL
    private var entries: [Entry] = []

    init() {
        directoryURL = Self.makeDirectory()
    }

    deinit {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// Writes one encoded frame to disk and returns its pool index plus a small UI preview image.
    func append(_ data: Data) -> (index: Int, thumbnail: UIImage)? {
        guard !data.isEmpty,
              let thumbCG = Self.makeThumbnailCGImage(from: data, maxPixel: 240),
              let sig = Self.signature(from: thumbCG) else { return nil }

        lock.lock()
        let idx = entries.count
        let dir = directoryURL
        lock.unlock()

        let fileURL = dir.appendingPathComponent(String(format: "frame-%05d.img", idx))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            return nil
        }

        lock.lock()
        let finalIndex = entries.count
        let storedURL: URL
        if finalIndex == idx {
            storedURL = fileURL
        } else {
            // Reset raced with append: discard orphaned write cleanly.
            try? FileManager.default.removeItem(at: fileURL)
            lock.unlock()
            return nil
        }
        entries.append(Entry(index: finalIndex, fileURL: storedURL, signature: sig))
        lock.unlock()
        return (finalIndex, UIImage(cgImage: thumbCG))
    }

    /// Deletes all stored frame files and prepares a fresh temporary directory.
    func reset() {
        lock.lock()
        let oldDir = directoryURL
        entries.removeAll()
        directoryURL = Self.makeDirectory()
        lock.unlock()
        try? FileManager.default.removeItem(at: oldDir)
    }

    /// Loads and normalizes a full-resolution `CGImage` at `poolIndex` on demand from disk.
    func loadCGImage(at poolIndex: Int) -> CGImage? {
        guard let url = url(for: poolIndex),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let normalized = try? ImageNormalizer.normalize(data: data) else { return nil }
        return normalized.image
    }

    /// Decodes a `SelectedImage` (full `CGImage` + strip thumbnail) at `poolIndex` from disk.
    func loadSelectedImage(at poolIndex: Int) throws -> SelectedImage {
        guard let url = url(for: poolIndex),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw ImageLoadError.decodeFailed
        }
        return try ImageDecoder.decode(data)
    }

    /// Selects a sparse primary keyframe subset (~`strideFraction` scroll per step) from the dense
    /// pool while keeping intermediate frames on disk for `StitchEngine` gap backfill.
    func selectPrimaryIndices(strideFraction: Float = 0.24) -> [Int] {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        guard snapshot.count > 2 else { return snapshot.map(\.index) }

        var cfg = FrameSelector.Config()
        cfg.minInterval = 0
        cfg.minScrollFraction = strideFraction
        cfg.maxFrames = snapshot.count
        let selector = FrameSelector.Engine(config: cfg)

        var chosen: [Int] = []
        for (step, entry) in snapshot.enumerated() {
            if selector.consider(entry.signature, at: TimeInterval(step)).isKeep {
                chosen.append(entry.index)
            }
        }
        if let last = snapshot.last, chosen.last != last.index {
            if let prevIdx = chosen.last {
                let prevSig = snapshot[prevIdx].signature
                if FrameSelector.meanAbsDiff(prevSig, last.signature) >= cfg.duplicateThreshold {
                    chosen.append(last.index)
                }
            } else {
                chosen.append(last.index)
            }
        }
        if chosen.count < 2 {
            return [snapshot[0].index, snapshot[snapshot.count - 1].index]
        }
        return chosen
    }

    private func url(for poolIndex: Int) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard entries.indices.contains(poolIndex) else { return nil }
        return entries[poolIndex].fileURL
    }

    private static func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PostShotCapture-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func makeThumbnailCGImage(from data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func signature(from image: CGImage, size: Int = 64) -> [Float]? {
        var gray = [UInt8](repeating: 0, count: size * size)
        let ok: Bool = gray.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(
                data: ptr.baseAddress, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: size,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        return ok ? gray.map { Float($0) / 255.0 } : nil
    }
}
