// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreGraphics
import Foundation

/// Normalized vertical span (`0...1`, top-down) occupied by a stitched segment in the output image.
struct SegmentSpan: Equatable, Sendable, Identifiable {
    let id: Int
    let sourceIndex: Int?
    let topFraction: CGFloat
    let bottomFraction: CGFloat
}

/// Merges vertically-overlapping images into a single tall canvas with midpoint hard-cut seams.
/// Uses sRGB, no resampling beyond width normalization.
///
/// Long screenshots share *identical* pixels in the overlap region (same UI, different scroll
/// offset), so we do NOT alpha-blend the seam. Instead each seam is placed at `overlap / 2` —
/// the vertical midpoint of the shared region — so any residual nav-bar hairline, drop shadow,
/// or frosted-glass tint sitting near either segment's outer edge falls inside the discarded half.
enum ImageCompositor {

    /// A source image paired with the overlap (in rows) it shares with the *previous* image.
    /// The first segment's `overlap` is ignored.
    struct Segment {
        let image: CGImage
        /// Overlap with the previous segment, in pixels of the common (normalized) width space.
        let overlap: Int
        /// 0-based index into the input image array, or `nil` for backfilled frames.
        let sourceIndex: Int?

        init(image: CGImage, overlap: Int, sourceIndex: Int? = nil) {
            self.image = image
            self.overlap = overlap
            self.sourceIndex = sourceIndex
        }
    }

    enum CompositeError: Error {
        case empty
        case contextCreationFailed
        case drawFailed
    }

    /// Composites segments top-to-bottom into one image of the given common width.
    static func composite(segments: [Segment], width: Int) throws -> CGImage {
        try composite(
            segments: segments,
            width: width,
            removeScrollIndicator: false,
            protectedTopRows: 0,
            protectedBottomRows: 0
        )
    }

    /// Composites segments top-to-bottom and optionally removes right-edge vertical scrollbars.
    static func composite(
        segments: [Segment],
        width: Int,
        removeScrollIndicator: Bool,
        protectedTopRows: Int = 0,
        protectedBottomRows: Int = 0
    ) throws -> CGImage {
        let layout = try computeLayout(segments: segments, width: width)
        guard width <= Int.max / 4, layout.totalHeight <= Int.max / (width * 4) else {
            throw CompositeError.contextCreationFailed
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: layout.totalHeight,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CompositeError.contextCreationFailed }
        ctx.interpolationQuality = segments.allSatisfy({ $0.image.width == width }) ? .none : .high

        drawSegments(segments, layout: layout, width: width, into: ctx)

        if removeScrollIndicator {
            ScrollIndicatorRemover.clean(
                context: ctx,
                segments: segments,
                scaledHeights: layout.scaledHeights,
                overlaps: layout.overlaps,
                totalHeight: layout.totalHeight,
                colorSpace: colorSpace,
                protectedTopRows: protectedTopRows,
                protectedBottomRows: protectedBottomRows
            )
        }

        guard let result = ctx.makeImage() else { throw CompositeError.drawFailed }
        return result
    }

    /// Computes normalized top-down vertical spans (`0...1`) matching the midpoint hard-cut seams.
    static func computeSegmentSpans(segments: [Segment], width: Int) throws -> [SegmentSpan] {
        let layout = try computeLayout(segments: segments, width: width)
        var topDownOrigins = [Int](repeating: 0, count: segments.count)
        for i in 1..<segments.count {
            topDownOrigins[i] = topDownOrigins[i - 1] + (layout.scaledHeights[i - 1] - layout.overlaps[i])
        }
        let seamTops = segments.indices.map { i in
            i == 0 ? 0 : topDownOrigins[i] + (layout.overlaps[i] / 2)
        }
        let total = CGFloat(max(1, layout.totalHeight))
        return segments.indices.map { i in
            let start = max(0, min(seamTops[i], layout.totalHeight))
            let rawEnd = (i + 1 < segments.count) ? seamTops[i + 1] : layout.totalHeight
            let end = max(start, min(rawEnd, layout.totalHeight))
            return SegmentSpan(
                id: i,
                sourceIndex: segments[i].sourceIndex,
                topFraction: CGFloat(start) / total,
                bottomFraction: CGFloat(end) / total
            )
        }
    }

    private struct Layout {
        let scaledHeights: [Int]
        let overlaps: [Int]
        let totalHeight: Int
    }

    private static func drawSegments(
        _ segments: [Segment], layout: Layout, width: Int, into ctx: CGContext
    ) {
        // CG origin is bottom-left; lay segments from the top (highest y) downward. For i > 0,
        // clip out the top half of the overlap (`cut = overlap / 2`) so the seam lands cleanly in
        // the interior of the shared region rather than along segment i's top edge.
        var topY = layout.totalHeight
        for (i, seg) in segments.enumerated() {
            let h = layout.scaledHeights[i]
            if i > 0 {
                topY -= (layout.scaledHeights[i - 1] - layout.overlaps[i])
            }
            let rect = CGRect(x: 0, y: CGFloat(topY - h), width: CGFloat(width), height: CGFloat(h))
            let cut = i > 0 ? (layout.overlaps[i] / 2) : 0
            if cut > 0, h > cut {
                ctx.saveGState()
                ctx.clip(to: CGRect(x: 0, y: CGFloat(topY - h), width: CGFloat(width), height: CGFloat(h - cut)))
                ctx.draw(seg.image, in: rect)
                ctx.restoreGState()
            } else {
                ctx.draw(seg.image, in: rect)
            }
        }
    }

    private static func computeLayout(segments: [Segment], width: Int) throws -> Layout {
        guard !segments.isEmpty, width > 0 else { throw CompositeError.empty }
        let scaledHeights: [Int] = segments.map { seg in
            let w = seg.image.width
            guard w > 0 else { return 0 }
            return Int((Float(seg.image.height) * Float(width) / Float(w)).rounded())
        }
        var overlaps = [Int](repeating: 0, count: segments.count)
        for i in 1..<segments.count {
            let cap = min(scaledHeights[i - 1], scaledHeights[i])
            overlaps[i] = clampOverlap(segments[i].overlap, cap)
        }
        var totalHeight = scaledHeights.first ?? 0
        for i in 1..<segments.count {
            let delta = max(0, scaledHeights[i] - overlaps[i])
            guard totalHeight <= Int.max - delta else { throw CompositeError.contextCreationFailed }
            totalHeight += delta
        }
        guard totalHeight > 0 else { throw CompositeError.empty }
        return Layout(scaledHeights: scaledHeights, overlaps: overlaps, totalHeight: totalHeight)
    }

    private static func clampOverlap(_ overlap: Int, _ height: Int) -> Int {
        max(0, min(overlap, height))
    }
}
