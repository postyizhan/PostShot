// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreGraphics
import Foundation

struct PixelSize: Equatable, CustomStringConvertible {
    let width: Int
    let height: Int
    var description: String { "\(width)×\(height)" }
}

enum InputDiagnosticReason: Equatable {
    case empty
    case nonPositiveDimensions
    case dimensionMismatch
    case impossiblePixelCount
}

struct InputDiagnostic: Equatable {
    let sourceIndex: Int
    let actual: PixelSize
    let expected: PixelSize?
    let reason: InputDiagnosticReason
}

struct StitchInputProfile: Equatable {
    let canonicalSize: PixelSize
    let diagnostics: [InputDiagnostic]

    var isValid: Bool { diagnostics.isEmpty }
}

enum StitchInputValidator {
    static func validate(_ images: [CGImage]) -> StitchInputProfile {
        guard let first = images.first else {
            return StitchInputProfile(canonicalSize: PixelSize(width: 0, height: 0), diagnostics: [InputDiagnostic(sourceIndex: 0, actual: PixelSize(width: 0, height: 0), expected: nil, reason: .empty)])
        }
        let canonical = PixelSize(width: first.width, height: first.height)
        var diagnostics: [InputDiagnostic] = []
        for (index, image) in images.enumerated() {
            let actual = PixelSize(width: image.width, height: image.height)
            let invalidCount = image.width > 0 && image.height > 0 && image.width <= Int.max / image.height ? false : true
            if image.width <= 0 || image.height <= 0 {
                diagnostics.append(InputDiagnostic(sourceIndex: index, actual: actual, expected: canonical, reason: .nonPositiveDimensions))
            } else if invalidCount {
                diagnostics.append(InputDiagnostic(sourceIndex: index, actual: actual, expected: canonical, reason: .impossiblePixelCount))
            } else if actual != canonical {
                diagnostics.append(InputDiagnostic(sourceIndex: index, actual: actual, expected: canonical, reason: .dimensionMismatch))
            }
        }
        return StitchInputProfile(canonicalSize: canonical, diagnostics: diagnostics)
    }
}
