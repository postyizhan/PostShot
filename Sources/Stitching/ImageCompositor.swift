import CoreGraphics
import Foundation

/// Merges vertically-overlapping images into a single tall canvas with feathered seams.
/// See SPEC §2.2. Uses sRGB, no resampling beyond width normalization.
enum ImageCompositor {

    /// A source image paired with the overlap (in rows) it shares with the *previous* image.
    /// The first segment's `overlap` is ignored.
    struct Segment {
        let image: CGImage
        /// Overlap with the previous segment, in pixels of the common (normalized) width space.
        let overlap: Int
    }

    /// Height of the alpha feather transition band (SPEC §2.2: ~20–30px).
    static let featherHeight = 24

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

        var totalHeight = 0
        for (i, h) in scaledHeights.enumerated() {
            totalHeight += (i == 0) ? h : max(0, h - clampOverlap(segments[i].overlap, h))
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
        var cursorTopY = totalHeight
        for (i, seg) in segments.enumerated() {
            let h = scaledHeights[i]
            let overlap = (i == 0) ? 0 : clampOverlap(seg.overlap, h)
            let segBottomY = cursorTopY - h
            let rect = CGRect(x: 0, y: CGFloat(segBottomY), width: CGFloat(width), height: CGFloat(h))

            if i == 0 || overlap == 0 {
                ctx.draw(seg.image, in: rect)
            } else {
                drawFeathered(ctx: ctx, image: seg.image, in: rect, overlap: overlap)
            }
            cursorTopY -= (i == 0) ? h : (h - overlap)
        }

        guard let result = ctx.makeImage() else { throw CompositeError.drawFailed }
        return result
    }

    private static func clampOverlap(_ overlap: Int, _ height: Int) -> Int {
        max(0, min(overlap, height))
    }

    // MARK: - Feathered draw

    /// Draws `image` into `rect`, ramping its top `band` rows from transparent to opaque so the
    /// previously-drawn content (the prior segment's tail) shows through the seam.
    private static func drawFeathered(ctx: CGContext, image: CGImage, in rect: CGRect, overlap: Int) {
        let band = min(featherHeight, overlap)
        guard band > 0, let mask = featherMask(width: Int(rect.width), height: Int(rect.height), band: band) else {
            ctx.draw(image, in: rect)
            return
        }
        ctx.saveGState()
        ctx.clip(to: rect, mask: mask)
        ctx.draw(image, in: rect)
        ctx.restoreGState()
    }

    /// Grayscale coverage mask the size of the (scaled) segment: white (opaque) everywhere except
    /// the top `band` rows, which ramp 0→1 downward. Used with `CGContext.clip(to:mask:)`.
    private static func featherMask(width: Int, height: Int, band: Int) -> CGImage? {
        guard width > 0, height > 0, band > 0, band <= height else { return nil }
        let gray = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: gray,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        // Fill white (fully opaque coverage).
        ctx.setGrayFillColor(gray: 1.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Top `band` rows live at the highest y (CG bottom-left origin): [height-band, height].
        // Ramp from black at the very top (y = height) to white at y = height-band.
        guard let gradient = CGGradient(
            colorsSpace: gray,
            colors: [
                CGColor(gray: 0.0, alpha: 1.0), // top → transparent coverage
                CGColor(gray: 1.0, alpha: 1.0), // bottom of band → opaque
            ] as CFArray,
            locations: [0.0, 1.0]
        ) else { return ctx.makeImage() }

        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: height - band, width: width, height: band))
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: height),          // top
            end: CGPoint(x: 0, y: height - band),     // bottom of band
            options: []
        )
        ctx.restoreGState()

        return ctx.makeImage()
    }
}
