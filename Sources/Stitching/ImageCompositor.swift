// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreGraphics
import Foundation

/// Merges vertically-overlapping images into a single tall canvas with hard-cut seams.
/// See SPEC §2.2. Uses sRGB, no resampling beyond width normalization.
///
/// Long screenshots share *identical* pixels in the overlap region (same UI, different scroll
/// offset), so we do NOT alpha-blend the seam. Blending two near-identical regions only
/// introduces a visible soft band wherever brightness changes (e.g. a dark bubble over a light
/// gap washes out to a pale line). Instead each segment is drawn opaque; the later segment's
/// top rows simply overwrite the previous segment's tail. Identical pixels → invisible seam.
enum ImageCompositor {

    /// A source image paired with the overlap (in rows) it shares with the *previous* image.
    /// The first segment's `overlap` is ignored.
    struct Segment {
        let image: CGImage
        /// Overlap with the previous segment, in pixels of the common (normalized) width space.
        let overlap: Int
    }

    enum CompositeError: Error {
        case empty
        case contextCreationFailed
        case drawFailed
    }

    /// Composites segments top-to-bottom into one image of the given common width.
    ///
    /// `width` is the normalized common width; all images are drawn scaled to it and heights
    /// scale proportionally. Overlap values are interpreted in this width space.
    static func composite(segments: [Segment], width: Int) throws -> CGImage {
        guard !segments.isEmpty, width > 0 else { throw CompositeError.empty }

        let scaledHeights: [Int] = segments.map { seg in
            let w = seg.image.width
            guard w > 0 else { return 0 }
            return Int((Float(seg.image.height) * Float(width) / Float(w)).rounded())
        }

        // Overlap of segment i with segment i-1, clamped to neither exceeding the previous
        // nor the current segment's height. Index 0 is unused (first segment has no predecessor).
        // The SAME clamped values drive both the canvas-height calc and segment placement, so
        // the two can never disagree.
        var overlaps = [Int](repeating: 0, count: segments.count)
        for i in 1..<segments.count {
            let cap = min(scaledHeights[i - 1], scaledHeights[i])
            overlaps[i] = clampOverlap(segments[i].overlap, cap)
        }

        var totalHeight = scaledHeights.first ?? 0
        for i in 1..<segments.count {
            totalHeight += max(0, scaledHeights[i] - overlaps[i])
        }
        guard totalHeight > 0 else { throw CompositeError.empty }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: totalHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CompositeError.contextCreationFailed }
        ctx.interpolationQuality = .high

        // CG origin is bottom-left; lay segments from the top (highest y) downward.
        // `topY` tracks the top edge of the segment about to be drawn. Before each non-first
        // segment we descend by the PREVIOUS segment's non-overlapping height, so the current
        // segment's top `overlaps[i]` rows land exactly on the previous segment's tail. Drawing
        // opaque in order then overwrites that tail — a hard cut between identical pixels.
        var topY = totalHeight
        for (i, seg) in segments.enumerated() {
            let h = scaledHeights[i]
            if i > 0 {
                topY -= (scaledHeights[i - 1] - overlaps[i])
            }
            let rect = CGRect(x: 0, y: CGFloat(topY - h), width: CGFloat(width), height: CGFloat(h))
            ctx.draw(seg.image, in: rect)
        }

        guard let result = ctx.makeImage() else { throw CompositeError.drawFailed }
        return result
    }

    private static func clampOverlap(_ overlap: Int, _ height: Int) -> Int {
        max(0, min(overlap, height))
    }
}
