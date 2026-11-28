// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import UIKit

/// Shared Apple-aligned monochrome visual constants for PostShot.
/// Keeps iOS 16+ compatibility without requiring asset catalog colors.
enum DesignTokens {
    /// Adaptive primary monochrome ink (black in Light, white in Dark).
    static let ink = Color(UIColor.label)

    /// Pressed monochrome ink shade for tactile feedback.
    static let inkPressed = Color(UIColor {
        $0.userInterfaceStyle == .dark
            ? UIColor(white: 0.84, alpha: 1)
            : UIColor(white: 0.22, alpha: 1)
    })

    /// Contrasting foreground placed on filled `ink` surfaces (white in Light, black in Dark).
    static let onInk = Color(UIColor.systemBackground)

    /// Subtle monochrome fill for secondary pills and resting surfaces.
    static let inkSubtle = Color(UIColor.secondarySystemFill)

    /// Primary brand tint.
    static let primary = ink

    /// Native iOS toggle switch green.
    static let toggleTint = Color(UIColor.systemGreen)

    /// Accent color used sparingly for warnings, seams, and callouts.
    static let accent = Color.orange

    /// Highlight color for stitch seam inspection indicators.
    static let seamWarning = Color.orange

    /// Semantic confirmation tint.
    static let success = Color(UIColor.systemGreen)

    /// Deep charcoal canvas backdrop for preview & seam review modes.
    static let editorBackground = Color(red: 0.04, green: 0.05, blue: 0.07)

    /// Subtle neutral ambient radial glow behind stitched canvas previews.
    static let editorGlow = Color.white.opacity(0.08)

    static let cardCornerRadius: CGFloat = 20
    static let capsuleSpacing: CGFloat = 8
}

/// Standardized Apple-style spring and easing curves.
enum AppleMotion {
    static let snappy: Animation = .spring(response: 0.30, dampingFraction: 0.85)
    static let smooth: Animation = .spring(response: 0.42, dampingFraction: 0.88)
    static let gentle: Animation = .easeInOut(duration: 0.24)

    /// Returns `nil` when Reduce Motion is enabled so transitions stay comfortable.
    static func animation(_ base: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : base
    }
}

private struct ReduceMotionAnimationModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: Value

    func body(content: Content) -> some View {
        content.animation(AppleMotion.animation(animation, reduceMotion: reduceMotion), value: value)
    }
}

extension View {
    /// Applies `AppleMotion` animations while honoring the user's Reduce Motion preference.
    func appleAnimation<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
        modifier(ReduceMotionAnimationModifier(animation: animation, value: value))
    }
}
