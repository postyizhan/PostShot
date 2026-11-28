// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// Neutral Liquid Glass centered bottom bar for the Preview state (`[编辑]  [导出与分享]`).
struct PreviewBottomBar: View {
    var canExport: Bool
    var canEdit: Bool
    var onShare: () -> Void
    var onEnterEdit: () -> Void

    var body: some View {
        LiquidGlassGroup(spacing: 14) {
            HStack(spacing: 14) {
                Button(action: onEnterEdit) {
                    HStack(spacing: 7) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 16, weight: .semibold))
                        Text("编辑")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 22)
                    .frame(height: 50)
                    .liquidGlass(in: Capsule(), interactive: true)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canEdit)
                .opacity(canEdit ? 1 : 0.45)

                Button(action: onShare) {
                    HStack(spacing: 7) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                        Text("导出")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(DesignTokens.onInk)
                    .padding(.horizontal, 22)
                    .frame(height: 50)
                    .background(DesignTokens.ink, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canExport)
                .opacity(canExport ? 1 : 0.45)
            }
        }
    }
}

/// Top action bar in Unified Edit Mode matching iOS 26 Photos (`取消` + optional status + dirty-yellow `完成`).
struct EditTopBar: View {
    var hasEdits: Bool
    var statusCaption: String?
    var onCancel: () -> Void
    var onDone: () -> Void

    private let photosYellow = Color(red: 1.0, green: 0.80, blue: 0.0)

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onCancel) {
                Text("取消")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .liquidGlass(in: Capsule(), interactive: true)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 6)

            if let statusCaption {
                Text(statusCaption)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .liquidGlass(in: Capsule())
                    .lineLimit(1)
                    .allowsHitTesting(false)
            }

            Spacer(minLength: 6)

            doneButton
        }
    }

    @ViewBuilder
    private var doneButton: some View {
        Button(action: onDone) {
            Text("完成")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(hasEdits ? DesignTokens.onInk : Color.secondary.opacity(0.55))
                .padding(.horizontal, 18)
                .frame(height: 44)
                .background {
                    if hasEdits {
                        Capsule().fill(DesignTokens.ink)
                    } else {
                        Capsule().fill(Color.clear).liquidGlass(in: Capsule())
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!hasEdits)
        .appleAnimation(AppleMotion.snappy, value: hasEdits)
    }
}

/// Second top row inside Unified Edit Mode for contextual sub-tabs (`顶部 | 底部 | 分段` or `打码 | 文字 | 画笔`).
struct EditSubSelectorBar: View {
    let editTab: EditorPrimaryTab
    @Binding var cropTab: CropAdjustTab
    @Binding var activeMarkupTool: EditorTool?
    var hasAnnotations: Bool
    var onUndo: () -> Void

    var body: some View {
        switch editTab {
        case .crop:
            HStack(spacing: 2) {
                ForEach(CropAdjustTab.allCases) { tab in
                    let isSelected = cropTab == tab
                    Button {
                        withAnimation(AppleMotion.snappy) { cropTab = tab }
                    } label: {
                        Text(tab.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                            .padding(.horizontal, 14)
                            .frame(height: 30)
                            .background(Capsule().fill(isSelected ? Color.primary.opacity(0.10) : Color.clear))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .frame(height: 38)
            .liquidGlass(in: Capsule(), interactive: true)

        case .markup:
            LiquidGlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        ForEach(EditorTool.allCases) { tool in
                            let isSelected = activeMarkupTool == tool
                            Button {
                                withAnimation(AppleMotion.snappy) {
                                    activeMarkupTool = isSelected ? nil : tool
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: tool.systemImage)
                                        .font(.system(size: 13, weight: .semibold))
                                    Text(tool.title)
                                        .font(.caption.weight(.semibold))
                                }
                                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                                .padding(.horizontal, 12)
                                .frame(height: 30)
                                .background(Capsule().fill(isSelected ? Color.primary.opacity(0.10) : Color.clear))
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(4)
                    .frame(height: 38)
                    .liquidGlass(in: Capsule(), interactive: true)

                    if hasAnnotations {
                        AdaptiveGlassCircleButton(
                            systemImage: "arrow.uturn.backward",
                            accessibilityLabel: "撤销",
                            size: 38,
                            action: onUndo
                        )
                    }
                }
            }

        case .beautify:
            EmptyView()
        }
    }
}
