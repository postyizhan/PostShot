// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import UIKit

/// Shared Apple-aligned visual constants for PostShot.
/// Keeps iOS 16+ compatibility without requiring asset catalog colors.
enum DesignTokens {
    /// Apple system-aligned blue adapting between light (#0071E3) and dark (#2997FF).
    static let accentBlue = Color(UIColor {
        $0.userInterfaceStyle == .dark
            ? UIColor(red: CGFloat(0x29) / 255.0, green: CGFloat(0x97) / 255.0, blue: 1, alpha: 1)
            : UIColor(red: 0, green: CGFloat(0x71) / 255.0, blue: CGFloat(0xE3) / 255.0, alpha: 1)
    })

    /// Primary brand tint.
    static let primary = accentBlue

    /// Deeper primary shade for pressed or highlighted states.
    static let primaryDeep = Color(UIColor {
        $0.userInterfaceStyle == .dark
            ? UIColor(red: CGFloat(0x1A) / 255.0, green: CGFloat(0x8A) / 255.0, blue: 1, alpha: 1)
            : UIColor(red: 0, green: CGFloat(0x66) / 255.0, blue: CGFloat(0xCC) / 255.0, alpha: 1)
    })

    /// Accent color used sparingly for warnings, seams, and callouts.
    static let accent = Color.orange

    /// Highlight color for stitch seam inspection indicators.
    static let seamWarning = Color.orange

    /// Semantic confirmation tint.
    static let success = Color(UIColor.systemGreen)

    /// Deep charcoal canvas backdrop for preview & seam review modes.
    static let editorBackground = Color(red: 0.04, green: 0.05, blue: 0.07)

    /// Subtle ambient radial glow behind stitched canvas previews.
    static let editorGlow = Color(red: 0.12, green: 0.24, blue: 0.42).opacity(0.38)

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
