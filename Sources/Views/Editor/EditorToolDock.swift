// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// Primary bottom modules inside Unified Edit Mode (matching iOS 26 Photos Edit layout).
enum EditorPrimaryTab: String, CaseIterable, Identifiable {
    case crop, markup, beautify

    var id: String { rawValue }

    var title: String {
        switch self {
        case .crop: return "裁剪"
        case .markup: return "标注"
        case .beautify: return "美化"
        }
    }

    var systemImage: String {
        switch self {
        case .crop: return "crop"
        case .markup: return "pencil.tip.crop.circle"
        case .beautify: return "sparkles"
        }
    }
}

/// Pure markup tools exposed in Unified Edit Mode when `EditorPrimaryTab.markup` is active.
enum EditorTool: String, CaseIterable, Identifiable {
    case redact, text, draw

    var id: String { rawValue }

    var title: String {
        switch self {
        case .redact: return "打码"
        case .text: return "文字"
        case .draw: return "画笔"
        }
    }

    var systemImage: String {
        switch self {
        case .redact: return "checkerboard.rectangle"
        case .text: return "textformat"
        case .draw: return "pencil.tip"
        }
    }
}

/// Single-row Liquid Glass primary 3-tab selector capsule (`裁剪 | 标注 | 美化`).
struct EditorPrimaryTabPill: View {
    @Binding var selectedTab: EditorPrimaryTab
    var modifiedTabs: Set<EditorPrimaryTab>

    private let dirtyDotYellow = Color(red: 1.0, green: 0.80, blue: 0.0)

    var body: some View {
        HStack(spacing: 4) {
            ForEach(EditorPrimaryTab.allCases) { tab in
                let isSelected = selectedTab == tab
                Button {
                    withAnimation(AppleMotion.snappy) { selectedTab = tab }
                } label: {
                    VStack(spacing: 2) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: tab.systemImage)
                                .font(.system(size: 15, weight: .semibold))
                            if modifiedTabs.contains(tab) {
                                Circle()
                                    .fill(dirtyDotYellow)
                                    .frame(width: 5, height: 5)
                                    .offset(x: 5, y: -3)
                            }
                        }
                        Text(tab.title)
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .frame(width: 68, height: 48)
                    .background(Capsule().fill(isSelected ? Color.primary.opacity(0.10) : Color.clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .frame(height: 56)
        .liquidGlass(in: Capsule(), interactive: true)
    }
}

/// Single-row floating Liquid Glass contextual sub-panel for the active markup tool.
struct EditorMarkupDock: View {
    @Binding var activeTool: EditorTool?
    @Binding var markup: EditorMarkupState
    var onAddTextSticker: () -> Void

    var body: some View {
        if let activeTool {
            HStack(spacing: 8) {
                contextualSubBar(for: activeTool)
            }
            .frame(minHeight: 44)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .liquidGlass(in: Capsule(), interactive: true)
            .padding(.horizontal, 12)
            .appleAnimation(AppleMotion.snappy, value: activeTool)
        }
    }

    @ViewBuilder
    private func contextualSubBar(for tool: EditorTool) -> some View {
        switch tool {
        case .redact: RedactSubBar(markup: $markup)
        case .text: TextSubBar(markup: $markup, onAddTextSticker: onAddTextSticker)
        case .draw: DrawSubBar(markup: $markup)
        }
    }
}

/// Single-row floating Liquid Glass contextual bar for corner radius, shadow, and frame styling.
struct EditorBeautifyDock: View {
    @Binding var markup: EditorMarkupState

    var body: some View {
        HStack(spacing: 8) {
            BeautifySubBar(markup: $markup)
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .liquidGlass(in: Capsule(), interactive: true)
        .padding(.horizontal, 12)
    }
}

// MARK: - Single-Row Sub-Bars

private struct RedactSubBar: View {
    @Binding var markup: EditorMarkupState
    private let autoTargets = ["头像", "昵称", "手机号", "金额"]

    var body: some View {
        HStack(spacing: 8) {
            RedactModeToggle(selection: $markup.redactMode)
            Menu { redactMenuContent } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
                    .background(Color.primary.opacity(0.08), in: Circle())
                    .contentShape(Circle())
            }
            .accessibilityLabel("打码选项")
            if markup.redactMode == .auto {
                Text("\(markup.autoRedactTargets.count)项")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(DesignTokens.accentBlue)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(DesignTokens.accentBlue.opacity(0.14), in: Capsule())
                    .lineLimit(1)
            } else {
                Text(markup.manualRedactStyle.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var redactMenuContent: some View {
        if markup.redactMode == .auto {
            ForEach(autoTargets, id: \.self) { target in
                Button { toggleAutoTarget(target) } label: {
                    if markup.autoRedactTargets.contains(target) {
                        Label(target, systemImage: "checkmark")
                    } else { Text(target) }
                }
            }
        } else {
            ForEach(ManualRedactStyle.allCases, id: \.self) { style in
                Button { markup.manualRedactStyle = style } label: {
                    if markup.manualRedactStyle == style {
                        Label(style.title, systemImage: "checkmark")
                    } else { Text(style.title) }
                }
            }
        }
    }

    private func toggleAutoTarget(_ target: String) {
        if markup.autoRedactTargets.contains(target) { markup.autoRedactTargets.remove(target) }
        else { markup.autoRedactTargets.insert(target) }
    }
}

private struct RedactModeToggle: View {
    @Binding var selection: RedactMode

    var body: some View {
        HStack(spacing: 2) {
            modeButton(.auto, title: "自动")
            modeButton(.manual, title: "手动")
        }
        .padding(3)
        .background(Color.primary.opacity(0.08), in: Capsule())
    }

    private func modeButton(_ mode: RedactMode, title: String) -> some View {
        let isSelected = selection == mode
        return Button { selection = mode } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(isSelected ? DesignTokens.accentBlue : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct TextSubBar: View {
    @Binding var markup: EditorMarkupState
    let onAddTextSticker: () -> Void
    private let swatches: [Color] = [.white, .black, .blue, .red, .yellow]

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onAddTextSticker) {
                Text("+ 文字")
                    .font(.caption.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(DesignTokens.accentBlue, in: Capsule()).lineLimit(1)
            }
            .buttonStyle(.plain)
            HStack(spacing: 2) {
                ForEach(Array(swatches.enumerated()), id: \.offset) { _, color in
                    ColorSwatchDot(color: color, isSelected: markup.textColor == color) { markup.textColor = color }
                }
            }
            Button { markup.textHasBackground.toggle() } label: {
                Image(systemName: markup.textHasBackground ? "text.bubble.fill" : "text.bubble")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(markup.textHasBackground ? Color.white : Color.primary)
                    .frame(width: 32, height: 32)
                    .background(markup.textHasBackground ? DesignTokens.accentBlue : Color.primary.opacity(0.08), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain).accessibilityLabel("文字底色气泡")
        }
    }
}

private struct DrawSubBar: View {
    @Binding var markup: EditorMarkupState
    @State private var showClearConfirm = false
    private let swatches: [Color] = [.red, .orange, .yellow, .green, .blue]

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(DrawBrushStyle.allCases, id: \.self) { style in
                    Button { markup.brushStyle = style } label: { Label(style.title, systemImage: style.systemImage) }
                }
            } label: {
                Image(systemName: markup.brushStyle.systemImage)
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(DesignTokens.accentBlue)
                    .frame(width: 32, height: 32)
                    .background(DesignTokens.accentBlue.opacity(0.14), in: Circle()).contentShape(Circle())
            }
            .accessibilityLabel("画笔样式")
            HStack(spacing: 2) {
                ForEach(Array(swatches.enumerated()), id: \.offset) { _, color in
                    ColorSwatchDot(color: color, isSelected: markup.brushColor == color) { markup.brushColor = color }
                }
            }
            BrushWidthChips(brushWidth: $markup.brushWidth)
            Button { showClearConfirm = true } label: {
                Image(systemName: "trash").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(markup.strokes.isEmpty ? Color.secondary.opacity(0.45) : Color.primary)
                    .frame(width: 32, height: 32).background(Color.primary.opacity(0.08), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain).disabled(markup.strokes.isEmpty).accessibilityLabel("清空画笔")
            .confirmationDialog("清空所有笔画？", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("清空笔画", role: .destructive) { markup.strokes.removeAll() }
                Button("取消", role: .cancel) {}
            }
        }
    }
}

private struct BeautifySubBar: View {
    @Binding var markup: EditorMarkupState

    var body: some View {
        HStack(spacing: 8) {
            DockFilterChip(
                title: markup.beautifyCornerRadius > 0 ? "圆角 \(Int(markup.beautifyCornerRadius))" : "圆角",
                isSelected: markup.beautifyCornerRadius > 0
            ) { cycleCornerRadius() }
            DockFilterChip(title: "阴影", isSelected: markup.beautifyShadow) { markup.beautifyShadow.toggle() }
            DockFilterChip(title: "外框", isSelected: markup.beautifyFrame) { markup.beautifyFrame.toggle() }
        }
    }

    private func cycleCornerRadius() {
        if markup.beautifyCornerRadius < 1 { markup.beautifyCornerRadius = 16 }
        else if markup.beautifyCornerRadius < 22 { markup.beautifyCornerRadius = 24 }
        else { markup.beautifyCornerRadius = 0 }
    }
}

// MARK: - Reusable Dock Controls

private struct DockFilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(isSelected ? DesignTokens.accentBlue : Color.primary.opacity(0.08), in: Capsule())
                .contentShape(Capsule()).lineLimit(1)
        }
        .buttonStyle(.plain)
    }
}

private struct ColorSwatchDot: View {
    let color: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle().fill(color).frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
                .overlay(Circle().strokeBorder(isSelected ? DesignTokens.accentBlue : .clear, lineWidth: 2.5).padding(-3))
                .frame(width: 44, height: 44).contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// 三档画笔粗细选择器，替代原先不可发现的可点击圆点。
private struct BrushWidthChips: View {
    @Binding var brushWidth: CGFloat

    private struct Tier: Identifiable {
        let id: String
        let title: String
        let value: CGFloat
    }

    private let tiers: [Tier] = [
        Tier(id: "thin",   title: "细", value: 3),
        Tier(id: "medium", title: "中", value: 6),
        Tier(id: "thick",  title: "粗", value: 10),
    ]

    private var activeTier: Tier {
        if brushWidth <= 4 { return tiers[0] }
        if brushWidth <= 8 { return tiers[1] }
        return tiers[2]
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tiers) { tier in
                let isSelected = activeTier.id == tier.id
                Button { brushWidth = tier.value } label: {
                    Text(tier.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(isSelected ? DesignTokens.accentBlue : Color.clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.08), in: Capsule())
        .accessibilityLabel("画笔粗细")
    }
}
