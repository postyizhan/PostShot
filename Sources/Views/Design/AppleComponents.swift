// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import UIKit

// MARK: - Circle Icon Buttons

private struct CirclePressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CirclePressButtonBody(configuration: configuration)
    }

    private struct CirclePressButtonBody: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var isEnabled
        let configuration: Configuration

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .opacity(isEnabled ? (configuration.isPressed ? 0.86 : 1) : 0.45)
                .animation(AppleMotion.animation(AppleMotion.snappy, reduceMotion: reduceMotion), value: configuration.isPressed)
        }
    }
}

/// Translucent dark-glass circular button for dark preview and review toolbars.
struct GlassCircleButton: View {
    private let systemImage: String
    private let accessibilityLabel: String
    private let tint: Color
    private let size: CGFloat
    private let action: () -> Void

    init(
        systemImage: String, accessibilityLabel: String,
        tint: Color = .white, size: CGFloat = 36, action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.tint = tint
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(ZStack {
                    Circle().fill(Color(white: 0.22, opacity: 0.55))
                    Circle().fill(.ultraThinMaterial)
                })
                .overlay(Circle().strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.22), Color.white.opacity(0.05)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                ))
                .shadow(color: Color.black.opacity(0.28), radius: 8, y: 3)
                .contentShape(Circle())
        }
        .buttonStyle(CirclePressButtonStyle())
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - iOS 26 Liquid Glass Primitives

/// Applies native Liquid Glass on iOS 26+ with an ultra-thin frosted material fallback on iOS 16–25.
struct LiquidGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    var interactive: Bool = false
    var tint: Color? = nil

    @available(iOS 26.0, *)
    private var resolvedGlass: Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(resolvedGlass, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: Color.black.opacity(0.08), radius: 10, y: 3)
        }
    }
}

/// Groups sibling Liquid Glass surfaces into a unified morphing container on iOS 26+.
struct LiquidGlassGroup<Content: View>: View {
    private let spacing: CGFloat
    private let content: () -> Content

    init(spacing: CGFloat = 12, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

/// Adaptive Liquid Glass circular icon button for floating toolbars.
struct AdaptiveGlassCircleButton: View {
    private let systemImage: String
    private let accessibilityLabel: String
    private let tint: Color
    private let size: CGFloat
    private let glassTint: Color?
    private let action: () -> Void

    init(
        systemImage: String, accessibilityLabel: String,
        tint: Color = .primary, size: CGFloat = 44, glassTint: Color? = nil, action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
        self.tint = tint
        self.size = size
        self.glassTint = glassTint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .liquidGlass(in: Circle(), interactive: true, tint: glassTint)
                .contentShape(Circle())
        }
        .buttonStyle(CirclePressButtonStyle())
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Capsule Button Styles

/// Full-width primary capsule CTA styled with adaptive monochrome ink and spring press feedback.
struct ApplePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration)
    }

    private struct PrimaryButtonBody: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var isEnabled
        let configuration: Configuration

        var body: some View {
            configuration.label
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(DesignTokens.onInk)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15).padding(.horizontal, 20)
                .background(configuration.isPressed ? DesignTokens.inkPressed : DesignTokens.ink, in: Capsule())
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(isEnabled ? 1 : 0.45)
                .animation(AppleMotion.animation(AppleMotion.snappy, reduceMotion: reduceMotion), value: configuration.isPressed)
        }
    }
}

/// Full-width secondary capsule button for complementary actions.
struct AppleSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SecondaryButtonBody(configuration: configuration)
    }

    private struct SecondaryButtonBody: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var isEnabled
        let configuration: Configuration

        var body: some View {
            configuration.label
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15).padding(.horizontal, 20)
                .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
                .animation(AppleMotion.animation(AppleMotion.snappy, reduceMotion: reduceMotion), value: configuration.isPressed)
        }
    }
}

/// Full-width text-only capsule button with subtle opacity feedback on press.
struct AppleGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GhostButtonBody(configuration: configuration)
    }

    private struct GhostButtonBody: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var isEnabled
        let configuration: Configuration

        var body: some View {
            configuration.label
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13).padding(.horizontal, 20)
                .contentShape(Capsule())
                .opacity(isEnabled ? (configuration.isPressed ? 0.5 : 1) : 0.4)
                .animation(AppleMotion.animation(AppleMotion.gentle, reduceMotion: reduceMotion), value: configuration.isPressed)
        }
    }
}

// MARK: - Toasts & Empty States

/// Floating frosted capsule toast for transient confirmation or status feedback.
struct AppleToastBanner: View {
    let message: String
    var systemImage: String = "checkmark.circle.fill"
    var tint: Color = DesignTokens.success

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).font(.subheadline.weight(.semibold)).foregroundStyle(tint)
            Text(message).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.14), radius: 12, y: 4)
    }
}

/// iOS 16-compatible empty state block matching Apple's centered editorial hierarchy.
struct AppleEmptyStateView: View {
    let systemImage: String
    let title: String
    let subtitle: String
    var tint: Color = .primary

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 68, height: 68)
                .background(tint.opacity(0.07), in: Circle())
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(title).font(.title3.weight(.semibold)).foregroundStyle(.primary).multilineTextAlignment(.center)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 320)
        .padding(.horizontal, 24).padding(.vertical, 32)
    }
}

// MARK: - Card & Capsule View Modifiers

/// Grouped elevated card surface adapting cleanly to light and dark appearances.
struct CardBackground: ViewModifier {
    var cornerRadius: CGFloat = DesignTokens.cardCornerRadius

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(Color(.secondarySystemGroupedBackground), in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
    }
}

/// Elevated porcelain-like card surface with hairline stroke and soft Apple shadows.
struct PorcelainCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 20

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(Color(.systemBackground), in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
            .shadow(color: Color.black.opacity(0.07), radius: 16, y: 4)
            .shadow(color: Color.black.opacity(0.03), radius: 2, y: 1)
    }
}

/// Compact pill-shaped status or metadata label modifier.
struct CapsuleLabelStyle: ViewModifier {
    var tint: Color = .primary

    func body(content: Content) -> some View {
        content
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(tint.opacity(0.09), in: Capsule())
            .foregroundStyle(tint)
    }
}

extension View {
    /// Applies native iOS 26 Liquid Glass with a translucent material fallback on earlier OS versions.
    func liquidGlass<S: Shape>(in shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        modifier(LiquidGlassModifier(shape: shape, interactive: interactive, tint: tint))
    }

    /// Applies the Apple HIG grouped card surface with continuous corners.
    func appleCard(cornerRadius: CGFloat = DesignTokens.cardCornerRadius) -> some View {
        modifier(CardBackground(cornerRadius: cornerRadius))
    }

    /// Applies an elevated porcelain card surface with layered shadows.
    func porcelainCardStyle(cornerRadius: CGFloat = 20) -> some View {
        modifier(PorcelainCardModifier(cornerRadius: cornerRadius))
    }

    /// Styles a compact metadata badge as a tinted capsule.
    func capsuleLabelStyle(tint: Color = .primary) -> some View {
        modifier(CapsuleLabelStyle(tint: tint))
    }
}
