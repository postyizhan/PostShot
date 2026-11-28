// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// Perspective-stacked 3-card screenshot illustration for the welcome step.
/// Renders adaptive light/dark cards joined by glowing blue vertical stitch seams.
struct OnboardingIllustrationView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var appeared = false

    var body: some View {
        ZStack {
            ambientGlow
            VStack(spacing: 6) {
                topHeaderCard
                    .offset(y: appeared ? 0 : -14)
                    .opacity(appeared ? 1 : 0)

                StitchSeamConnector(active: appeared)

                middleMediaCard
                    .scaleEffect(appeared ? 1 : 0.94)
                    .opacity(appeared ? 1 : 0)

                StitchSeamConnector(active: appeared)

                bottomSummaryCard
                    .offset(y: appeared ? 0 : 14)
                    .opacity(appeared ? 1 : 0)
            }
            .rotation3DEffect(
                .degrees(appeared ? 6 : 12),
                axis: (x: 1, y: 0, z: 0),
                perspective: 0.45
            )
            .shadow(color: shadowColor, radius: 22, y: 12)
        }
        .padding(.vertical, 8)
        .accessibilityHidden(true)
        .onAppear(perform: triggerAppear)
    }

    // MARK: - Subviews

    private var ambientGlow: some View {
        Ellipse()
            .fill(DesignTokens.ink.opacity(colorScheme == .dark ? 0.12 : 0.06))
            .frame(width: 240, height: 180)
            .blur(radius: 36)
    }

    private var topHeaderCard: some View {
        IllustrationCardShell {
            HStack(spacing: 10) {
                Circle()
                    .fill(DesignTokens.ink.opacity(0.10))
                    .frame(width: 30, height: 30)
                    .overlay(
                        Circle()
                            .strokeBorder(DesignTokens.ink.opacity(0.22), lineWidth: 1)
                    )
                VStack(alignment: .leading, spacing: 6) {
                    SkeletonLine(widthFactor: 0.62, accent: false)
                    SkeletonLine(widthFactor: 0.40, accent: true)
                }
            }
        }
    }

    private var middleMediaCard: some View {
        IllustrationCardShell {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    SkeletonLine(widthFactor: 0.84, accent: false)
                    SkeletonLine(widthFactor: 0.56, accent: true)
                }
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                DesignTokens.ink.opacity(0.16),
                                Color(.tertiarySystemFill),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 50, height: 32)
            }
        }
    }

    private var bottomSummaryCard: some View {
        IllustrationCardShell {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    SkeletonLine(widthFactor: 0.72, accent: false)
                    SkeletonLine(widthFactor: 0.46, accent: true)
                    SkeletonLine(widthFactor: 0.60, accent: false)
                }
                Circle()
                    .fill(DesignTokens.ink.opacity(0.12))
                    .frame(width: 34, height: 34)
                    .overlay(
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(DesignTokens.ink)
                    )
            }
        }
    }

    private var shadowColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.45) : Color.black.opacity(0.12)
    }

    private func triggerAppear() {
        if reduceMotion {
            appeared = true
        } else {
            withAnimation(AppleMotion.smooth.delay(0.06)) {
                appeared = true
            }
        }
    }
}

// MARK: - Supporting Illustration Primitives

private struct IllustrationCardShell<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        content()
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(width: 224)
            .background(Color(.secondarySystemGroupedBackground), in: shape)
            .overlay(
                shape.strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
    }
}

private struct SkeletonLine: View {
    let widthFactor: CGFloat
    let accent: Bool

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(accent ? Color(.quaternaryLabel) : Color(.tertiaryLabel))
                .frame(width: max(24, geo.size.width * widthFactor), height: 6)
        }
        .frame(height: 6)
    }
}

private struct StitchSeamConnector: View {
    let active: Bool

    var body: some View {
        ZStack {
            Capsule()
                .fill(DesignTokens.ink.opacity(active ? 0.25 : 0))
                .frame(width: 8, height: 14)
                .blur(radius: 4)
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            DesignTokens.ink.opacity(0.3),
                            DesignTokens.ink,
                            DesignTokens.ink.opacity(0.3),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 2.5, height: 14)
                .scaleEffect(y: active ? 1 : 0.2)
        }
        .opacity(active ? 1 : 0)
    }
}
