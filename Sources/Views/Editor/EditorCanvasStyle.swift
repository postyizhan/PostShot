// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import UIKit

/// iOS 16+ proportional rounded rectangle matching `MarkupExportRenderer` corner scaling.
struct ScaledCanvasRoundedRect: InsettableShape {
    var baseCornerRadius: CGFloat
    var topCorners: Bool = true
    var bottomCorners: Bool = true
    var referenceCanvasSize: CGSize? = nil
    var insetAmount: CGFloat = 0

    var animatableData: CGFloat {
        get { baseCornerRadius }
        set { baseCornerRadius = newValue }
    }

    func inset(by amount: CGFloat) -> ScaledCanvasRoundedRect {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let insetRect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard insetRect.width > 0, insetRect.height > 0 else { return Path() }

        let targetSize = referenceCanvasSize ?? rect.size
        let rawRadius = EditorMarkupState.scaledCornerRadius(baseCornerRadius, for: targetSize)
        let maxHeightRadius = (topCorners && bottomCorners) ? insetRect.height * 0.5 : insetRect.height
        let radius = min(min(insetRect.width * 0.5, maxHeightRadius), max(0, rawRadius - insetAmount))

        guard radius > 0, topCorners || bottomCorners else {
            return Path(insetRect)
        }
        if topCorners && bottomCorners {
            return Path(UIBezierPath(roundedRect: insetRect, cornerRadius: radius).cgPath)
        }
        var corners: UIRectCorner = []
        if topCorners { corners.formUnion([.topLeft, .topRight]) }
        if bottomCorners { corners.formUnion([.bottomLeft, .bottomRight]) }
        let bezier = UIBezierPath(
            roundedRect: insetRect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(bezier.cgPath)
    }
}

/// Applies unified Beautify corner radius, border hairline/frame, and shadow to editor image canvases.
struct EditorCanvasBeautifyModifier: ViewModifier {
    let markup: EditorMarkupState

    func body(content: Content) -> some View {
        let shape = ScaledCanvasRoundedRect(baseCornerRadius: markup.beautifyCornerRadius)
        content
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(
                    Color.primary.opacity(markup.beautifyFrame ? 0.18 : 0.06),
                    lineWidth: markup.beautifyFrame ? 2 : 0.75
                )
            }
            .shadow(
                color: Color.black.opacity(markup.beautifyShadow ? 0.08 : 0),
                radius: markup.beautifyShadow ? 16 : 0,
                y: markup.beautifyShadow ? 4 : 0
            )
            .shadow(
                color: Color.black.opacity(markup.beautifyShadow ? 0.03 : 0),
                radius: markup.beautifyShadow ? 2 : 0,
                y: markup.beautifyShadow ? 1 : 0
            )
            .appleAnimation(AppleMotion.snappy, value: markup.beautifyCornerRadius)
            .appleAnimation(AppleMotion.snappy, value: markup.beautifyShadow)
            .appleAnimation(AppleMotion.snappy, value: markup.beautifyFrame)
    }
}

extension View {
    /// Applies unified Beautify corner radius, frame, and shadow matching `MarkupExportRenderer`.
    func editorCanvasBeautify(_ markup: EditorMarkupState) -> some View {
        modifier(EditorCanvasBeautifyModifier(markup: markup))
    }
}
