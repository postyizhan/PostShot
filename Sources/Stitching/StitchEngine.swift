// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreGraphics
import Foundation

struct StitchSeam: Equatable {
    let topIndex: Int
    let bottomIndex: Int
    let result: OverlapResult
}

final class StitchEngine: @unchecked Sendable {
    struct Options {
        var detectorConfig: OverlapDetector.Config = .init()
        var topCropFraction: Float = 0
        var bottomCropFraction: Float = 0
    }

    enum StitchError: Error {
        case noImages
        case invalidInput(profile: StitchInputProfile)
        case unsafeSeam(seam: StitchSeam)
        case compositeFailed(Error)
    }

    typealias ProgressHandler = (Double) -> Void
    private let queue = DispatchQueue(label: "com.postshot.stitch", qos: .userInitiated)

    func stitch(images: [CGImage], options: Options = Options(), progress: @escaping ProgressHandler,
                completion: @escaping (Result<CGImage, StitchError>) -> Void) {
        queue.async {
            let outcome = autoreleasepool {
                self.stitchSync(images: images, options: options, progress: progress)
            }
            completion(outcome)
        }
    }

    func stitchSync(images rawImages: [CGImage], options: Options = Options(),
                    progress: ProgressHandler = { _ in }) -> Result<CGImage, StitchError> {
        guard !rawImages.isEmpty else { return .failure(.noImages) }
        let croppedResult = cropAll(rawImages, options: options)
        guard case .success(let images) = croppedResult else { return croppedResult.map { $0[0] } }

        let profile = StitchInputValidator.validate(images)
        guard profile.isValid else { return .failure(.invalidInput(profile: profile)) }

        var segments = [ImageCompositor.Segment(image: images[0], overlap: 0)]
        if images.count > 1 {
            let buffers = images.map { PixelBuffer.from($0) }
            let pairCount = images.count - 1
            for index in 1..<images.count {
                let match: OverlapResult
                if let topBuf = buffers[index - 1], let bottomBuf = buffers[index] {
                    match = OverlapDetector.detect(top: topBuf, bottom: bottomBuf, config: options.detectorConfig)
                } else {
                    match = OverlapDetector.detect(top: images[index - 1], bottom: images[index], config: options.detectorConfig)
                }
                switch match.status {
                case .matched:
                    segments.append(ImageCompositor.Segment(image: images[index], overlap: match.overlap))
                case .duplicate:
                    break
                case .noOverlap:
                    segments.append(ImageCompositor.Segment(image: images[index], overlap: 0))
                case .ambiguous, .insufficientEvidence, .invalidInput:
                    return .failure(.unsafeSeam(seam: StitchSeam(topIndex: index - 1, bottomIndex: index, result: match)))
                }
                progress(Double(index) / Double(pairCount) * 0.7)
            }
        }
        do {
            let output = try ImageCompositor.composite(segments: segments, width: profile.canonicalSize.width)
            progress(1)
            return .success(output)
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
