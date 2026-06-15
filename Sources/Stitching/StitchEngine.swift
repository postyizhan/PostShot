// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreGraphics
import Foundation

/// Orchestrates stitching a sequence of screenshots into one long image.
///
/// Runs on a background queue and reports progress (SPEC §2.3). Reduces the input
/// pairwise: detect overlap between consecutive images, then composite all at once.
final class StitchEngine {

    struct Options {
        var detectorConfig: OverlapDetector.Config = .init()
        /// Optional manual crop applied to every image before detection/compositing.
        /// Values are fractions of height, 0...1 (SPEC §2.1 step 4 manual bars).
        var topCropFraction: Float = 0
        var bottomCropFraction: Float = 0
    }

    enum StitchError: Error {
        case noImages
        case compositeFailed(Error)
    }

    /// Progress is reported in 0...1 over the detection + composite phases.
    typealias ProgressHandler = (Double) -> Void

    private let queue = DispatchQueue(label: "com.longshot.stitch", qos: .userInitiated)

    /// Stitches `images` top-to-bottom. Calls `progress` on an arbitrary queue, then
    /// `completion` with the result on an arbitrary queue. Callers marshal to main.
    func stitch(
        images: [CGImage],
        options: Options = Options(),
        progress: @escaping ProgressHandler,
        completion: @escaping (Result<CGImage, StitchError>) -> Void
    ) {
        queue.async {
            let result = self.stitchSync(images: images, options: options, progress: progress)
            completion(result)
        }
    }

    /// Synchronous stitch — pure aside from logging; used directly by tests.
    func stitchSync(
        images rawImages: [CGImage],
        options: Options = Options(),
        progress: ProgressHandler = { _ in }
    ) -> Result<CGImage, StitchError> {
        guard !rawImages.isEmpty else { return .failure(.noImages) }

        // Apply manual crop, if any.
        let images = rawImages.map { Self.applyCrop($0, top: options.topCropFraction, bottom: options.bottomCropFraction) }

        // Common width = min width across inputs (downscale wider, never upscale-blur).
        let commonWidth = images.map { $0.width }.min() ?? images[0].width
        guard commonWidth > 0 else { return .failure(.noImages) }

        if images.count == 1 {
            progress(1.0)
            let seg = ImageCompositor.Segment(image: images[0], overlap: 0)
            return composite([seg], width: commonWidth)
        }

        // Detection phase: overlaps between consecutive pairs, in common-width space.
        var segments: [ImageCompositor.Segment] = [ImageCompositor.Segment(image: images[0], overlap: 0)]
        let pairCount = images.count - 1
        for i in 1..<images.count {
            let top = images[i - 1]
            let bottom = images[i]
            let result = OverlapDetector.detect(top: top, bottom: bottom, config: options.detectorConfig)

            if result.isDuplicate {
                // Near-identical frame: skip it entirely (SPEC §2.1 step 5).
            } else {
                // Overlap is measured on PixelBuffer height == source pixel height.
                // Convert bottom-image overlap rows into common-width space.
                let scale = Float(commonWidth) / Float(bottom.width)
                let overlapCommon = Int((Float(result.overlap) * scale).rounded())
                segments.append(ImageCompositor.Segment(image: bottom, overlap: overlapCommon))
            }
            progress(Double(i) / Double(pairCount) * 0.7)
        }

        let outcome = composite(segments, width: commonWidth)
        progress(1.0)
        return outcome
    }

    private func composite(_ segments: [ImageCompositor.Segment], width: Int) -> Result<CGImage, StitchError> {
        do {
            return .success(try ImageCompositor.composite(segments: segments, width: width))
        } catch {
            return .failure(.compositeFailed(error))
        }
    }

    // MARK: - Manual crop

    /// Crops `top`/`bottom` fractions off an image (used to drop static status/nav bars).
    static func applyCrop(_ image: CGImage, top: Float, bottom: Float) -> CGImage {
        let t = max(0, min(top, 0.49))
        let b = max(0, min(bottom, 0.49))
        guard t > 0 || b > 0 else { return image }
        let h = image.height
        let topPx = Int(Float(h) * t)
        let bottomPx = Int(Float(h) * b)
        let newHeight = h - topPx - bottomPx
        guard newHeight > 0 else { return image }
        let rect = CGRect(x: 0, y: topPx, width: image.width, height: newHeight)
        return image.cropping(to: rect) ?? image
    }
}
