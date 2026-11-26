// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreGraphics
import Foundation

struct StitchSeam: Equatable {
    let topIndex: Int
    let bottomIndex: Int
    let result: OverlapResult
}

/// Supplies dense intermediate frames recorded between adjacent primary frames so `StitchEngine`
/// can automatically backfill fast-scroll gaps or rescue trailing content right before an outlier.
struct FrameBackfillSource: @unchecked Sendable {
    /// Pool index corresponding to each image passed into `StitchEngine` (`count == images.count`).
    let poolIndices: [Int]
    /// Loads an uncropped full-resolution `CGImage` at `poolIndex` from the recording pool.
    let loadFrame: @Sendable (Int) -> CGImage?
}

struct StitchReport {
    let image: CGImage
    /// 0-based indices into the input `images` array skipped as non-connecting outliers.
    let skippedIndices: [Int]
    /// Number of intermediate frames automatically pulled from `FrameBackfillSource`.
    let backfilledCount: Int
}

final class StitchEngine: @unchecked Sendable {
    struct Options {
        var detectorConfig: OverlapDetector.Config = .init()
        var topCropFraction: Float = 0
        var bottomCropFraction: Float = 0
        /// Maximum consecutive non-connecting frames (e.g. Control Center) skipped automatically.
        var maxSkippedOutliers: Int = 3
        var backfill: FrameBackfillSource? = nil
    }

    enum StitchError: Error {
        case noImages
        case invalidInput(profile: StitchInputProfile)
        case unsafeSeam(seam: StitchSeam)
        case compositeFailed(Error)
    }

    typealias ProgressHandler = (Double) -> Void
    private let queue = DispatchQueue(label: "com.postshot.stitch", qos: .userInitiated)

    func stitch(
        images: [CGImage], options: Options = Options(), progress: @escaping ProgressHandler,
        completion: @escaping (Result<CGImage, StitchError>) -> Void
    ) {
        stitchWithReport(images: images, options: options, progress: progress) { result in
            completion(result.map(\.image))
        }
    }

    func stitchWithReport(
        images: [CGImage], options: Options = Options(), progress: @escaping ProgressHandler,
        completion: @escaping (Result<StitchReport, StitchError>) -> Void
    ) {
        queue.async {
            let outcome = autoreleasepool {
                self.stitchWithReportSync(images: images, options: options, progress: progress)
            }
            completion(outcome)
        }
    }

    func stitchSync(
        images rawImages: [CGImage], options: Options = Options(),
        progress: ProgressHandler = { _ in }
    ) -> Result<CGImage, StitchError> {
        stitchWithReportSync(images: rawImages, options: options, progress: progress).map(\.image)
    }

    func stitchWithReportSync(
        images rawImages: [CGImage], options: Options = Options(),
        progress: ProgressHandler = { _ in }
    ) -> Result<StitchReport, StitchError> {
        guard !rawImages.isEmpty else { return .failure(.noImages) }
        guard case .success(let images) = cropAll(rawImages, options: options) else {
            return cropAll(rawImages, options: options).map {
                StitchReport(image: $0[0], skippedIndices: [], backfilledCount: 0)
            }
        }

        let profile = StitchInputValidator.validate(images)
        guard profile.isValid else { return .failure(.invalidInput(profile: profile)) }

        let resolved = StitchGraphResolver.resolve(
            images: images, options: options,
            canonicalSize: profile.canonicalSize, progress: progress
        )
        guard case .success(let chain) = resolved else {
            return resolved.map { StitchReport(image: $0.segments[0].image, skippedIndices: [], backfilledCount: 0) }
        }
        do {
            let output = try ImageCompositor.composite(
                segments: chain.segments, width: profile.canonicalSize.width
            )
            progress(1)
            return .success(StitchReport(
                image: output,
                skippedIndices: chain.skippedIndices,
                backfilledCount: chain.backfilledCount
            ))
        } catch {
            return .failure(.compositeFailed(error))
        }
    }

    private func cropAll(_ rawImages: [CGImage], options: Options) -> Result<[CGImage], StitchError> {
        var images: [CGImage] = []
        images.reserveCapacity(rawImages.count)
        var cropDiagnostics: [InputDiagnostic] = []
        for (index, image) in rawImages.enumerated() {
            do {
                images.append(try ImageNormalizer.crop(
                    image, topFraction: options.topCropFraction, bottomFraction: options.bottomCropFraction
                ))
            } catch {
                cropDiagnostics.append(InputDiagnostic(
                    sourceIndex: index,
                    actual: PixelSize(width: image.width, height: image.height),
                    expected: nil,
                    reason: .nonPositiveDimensions
                ))
            }
        }
        if !cropDiagnostics.isEmpty {
            return .failure(.invalidInput(profile: StitchInputProfile(
                canonicalSize: PixelSize(width: 0, height: 0), diagnostics: cropDiagnostics
            )))
        }
        return .success(images)
    }
}
