// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreGraphics
import Foundation
import ImageIO

/// The single boundary at which encoded images become canonical stitch rasters.
enum ImageNormalizer {
    enum Error: Swift.Error, Equatable {
        case sourceCreationFailed
        case metadataInvalid
        case decodeFailed
        case contextCreationFailed
        case cropFailed
    }

    struct Diagnostics: Equatable {
        let sourceSize: PixelSize
        let normalizedSize: PixelSize
        let orientation: Int
    }

    struct Output {
        let image: CGImage
        let diagnostics: Diagnostics
    }

    static func normalize(data: Data, orientationOverride: Int? = nil) throws -> Output {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw Error.sourceCreationFailed
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let embeddedOrientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let orientation = orientationOverride ?? embeddedOrientation
        guard (1...8).contains(orientation),
              let widthValue = properties?[kCGImagePropertyPixelWidth] as? NSNumber,
              let heightValue = properties?[kCGImagePropertyPixelHeight] as? NSNumber,
              widthValue.intValue > 0, heightValue.intValue > 0 else {
            throw Error.metadataInvalid
        }

        let sourceSize = PixelSize(width: widthValue.intValue, height: heightValue.intValue)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(sourceSize.width, sourceSize.height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        let transformedSource: CGImageSource
        if orientation == embeddedOrientation {
            transformedSource = source
        } else {
            guard let rewritten = sourceByOverridingOrientation(
                source,
                orientation: orientation
            ) else { throw Error.decodeFailed }
            transformedSource = rewritten
        }
        guard let upright = CGImageSourceCreateThumbnailAtIndex(
            transformedSource,
            0,
            options as CFDictionary
        ) else {
            throw Error.decodeFailed
        }
        let image = try convertToCanonicalColorSpace(upright)
        return Output(
            image: image,
            diagnostics: Diagnostics(
                sourceSize: sourceSize,
                normalizedSize: PixelSize(width: image.width, height: image.height),
                orientation: orientation
            )
        )
    }

    static func normalize(_ image: CGImage) throws -> CGImage {
        guard image.width > 0, image.height > 0 else { throw Error.metadataInvalid }
        return try convertToCanonicalColorSpace(image)
    }

    static func crop(_ image: CGImage, topFraction: Float, bottomFraction: Float) throws -> CGImage {
        guard topFraction.isFinite, bottomFraction.isFinite else { throw Error.cropFailed }
        let top = max(0, min(topFraction, 0.49))
        let bottom = max(0, min(bottomFraction, 0.49))
        let topPixels = Int((Float(image.height) * top).rounded(.down))
        let bottomPixels = Int((Float(image.height) * bottom).rounded(.down))
        let height = image.height - topPixels - bottomPixels
        guard image.width > 0, height > 0 else { throw Error.cropFailed }
        // CGImage cropping rectangles use the image raster's top-left row convention.
        guard let result = image.cropping(to: CGRect(x: 0, y: topPixels, width: image.width, height: height)) else {
            throw Error.cropFailed
        }
        return result
    }

    private static func sourceByOverridingOrientation(
        _ source: CGImageSource,
        orientation: Int
    ) -> CGImageSource? {
        let data = NSMutableData()
        guard let type = CGImageSourceGetType(source),
              let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else {
            return nil
        }
        let properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
        CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return CGImageSourceCreateWithData(data as CFData, nil)
    }

    private static func convertToCanonicalColorSpace(_ image: CGImage) throws -> CGImage {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, width <= Int.max / 4, (width * 4) <= Int.max / height else {
            throw Error.metadataInvalid
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw Error.contextCreationFailed
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw Error.decodeFailed }
        return result
    }
}
