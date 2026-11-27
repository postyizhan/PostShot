// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// Workflow modes available in onboarding and settings tutorials.
enum TutorialMode: String, CaseIterable, Identifiable {
    case manual
    case auto
    case record

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: return "手动拼图"
        case .auto:   return "自动发现"
        case .record: return "滚动录屏"
        }
    }

    var subtitle: String {
        switch self {
        case .manual: return "自由选图 · 手动调整顺序"
        case .auto:   return "自动聚合截图 · 智能恢复顺序"
        case .record: return "后台实时抽帧 · 边滚边拼"
        }
    }

    var icon: String {
        switch self {
        case .manual: return "photo.on.rectangle.angled"
        case .auto:   return "wand.and.stars"
        case .record: return "record.circle"
        }
    }

    var tint: Color {
        switch self {
        case .manual: return DesignTokens.accentBlue
        case .auto:   return Color.indigo
        case .record: return Color.red
        }
    }
}

/// Apple-style paged modal tutorial with custom stylized visual cards for each step.
struct GuideTutorialSheet: View {
    let mode: TutorialMode

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0

    private var pages: [TutorialPage] { TutorialPage.pages(for: mode) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, item in
                        TutorialPageSlide(
                            page: item,
                            stepIndex: index,
                            totalSteps: pages.count,
                            accent: mode.tint
                        )
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                bottomControls
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                        .font(.body.weight(.medium))
                }
            }
        }
    }

    private var bottomControls: some View {
        VStack(spacing: 8) {
            Button(action: handlePrimaryTap) {
                Text(page < pages.count - 1 ? "下一步" : "完成")
            }
            .buttonStyle(ApplePrimaryButtonStyle())

            if page > 0 {
                Button("上一步") {
                    withAnimation(AppleMotion.animation(AppleMotion.snappy, reduceMotion: reduceMotion)) {
                        page -= 1
                    }
                }
                .buttonStyle(AppleGhostButtonStyle())
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    private func handlePrimaryTap() {
        if page < pages.count - 1 {
            withAnimation(AppleMotion.animation(AppleMotion.snappy, reduceMotion: reduceMotion)) {
                page += 1
            }
        } else {
            dismiss()
        }
    }
}

// MARK: - Slide Card

private struct TutorialPageSlide: View {
    let page: TutorialPage
    let stepIndex: Int
    let totalSteps: Int
    let accent: Color

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 12)
            visualCard
            textBlock
            Spacer(minLength: 28)
        }
        .padding(.horizontal, 24)
    }

    private var visualCard: some View {
        VStack(spacing: 16) {
            HStack {
                Text("第 \(stepIndex + 1) / \(totalSteps) 步")
                    .capsuleLabelStyle(tint: accent)
                Spacer()
                Image(systemName: page.badgeIcon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(accent.opacity(0.08))
                    .frame(height: 148)

                VStack(spacing: 12) {
                    Image(systemName: page.icon)
                        .font(.system(size: 46, weight: .medium))
                        .foregroundStyle(accent)
                        .symbolRenderingMode(.hierarchical)

                    Text(page.previewTag)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Color(.tertiarySystemGroupedBackground), in: Capsule())
                }
            }
        }
        .padding(20)
        .appleCard()
    }

    private var textBlock: some View {
        VStack(spacing: 8) {
            Text(page.title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)

            Text(page.body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
        }
    }
}

// MARK: - Page Data

private struct TutorialPage {
    let icon: String
    let badgeIcon: String
    let previewTag: String
    let title: String
    let body: String

    static func pages(for mode: TutorialMode) -> [TutorialPage] {
        switch mode {
        case .manual: return manualPages
        case .auto:   return autoPages
        case .record: return recordPages
        }
    }

    private static let manualPages: [TutorialPage] = [
        TutorialPage(
            icon: "photo.on.rectangle.angled",
            badgeIcon: "1.circle",
            previewTag: "支持单次最多选取 20 张截图",
            title: "选取连续截图",
            body: "点击「选择截图」，从系统相册中按内容或顺序挑出同一页面截取的多张图片。"
        ),
        TutorialPage(
            icon: "arrow.left.arrow.right.square",
            badgeIcon: "2.circle",
            previewTag: "底部缩略图条快捷调序",
            title: "核对顺序与删减",
            body: "通过缩略图条微调先后顺序或移除多余截图，确保相邻画面存在可识别的重叠区域。"
        ),
        TutorialPage(
            icon: "wand.and.rays",
            badgeIcon: "3.circle",
            previewTag: "边缘对齐 · 接缝微调",
            title: "一键拼合与微调",
            body: "自动匹配重叠边界并生成长图，可在审阅页微调接缝位置、保留眉头或一键分享保存。"
        ),
    ]

    private static let autoPages: [TutorialPage] = [
        TutorialPage(
            icon: "sparkles.rectangle.stack",
            badgeIcon: "1.circle",
            previewTag: "按拍摄时间与比例自动分组",
            title: "自动发现连续截图",
            body: "打开「自动」标签后，App 会扫描最近截图并把同一连续滚动操作聚合成候选群组。"
        ),
        TutorialPage(
            icon: "arrow.triangle.branch",
            badgeIcon: "2.circle",
            previewTag: "自动剔除重复与离群帧",
            title: "还原滚动顺序直接拼",
            body: "点击任一截图组，系统会自动恢复滚动顺序并过滤无效截图，直接进入长图审阅。"
        ),
    ]

    private static let recordPages: [TutorialPage] = [
        TutorialPage(
            icon: "record.circle",
            badgeIcon: "1.circle",
            previewTag: "ReplayKit 屏幕录制扩展",
            title: "启动滚动录屏",
            body: "点击「开始录屏」并选择「驿站截图」，倒计时结束后切换至你要截取的应用页面。"
        ),
        TutorialPage(
            icon: "hand.draw",
            badgeIcon: "2.circle",
            previewTag: "慢速匀速向下滑动效果最佳",
            title: "匀速滑动采集画面",
            body: "听到提示音或顶部指示变红后，在目标页面匀速向下滚动，扩展会实时抽帧传回。"
        ),
        TutorialPage(
            icon: "checkmark.rectangle.stack",
            badgeIcon: "3.circle",
            previewTag: "本地回环传输 · 隐私不离机",
            title: "停录后一键审阅拼接",
            body: "点击系统状态栏停止录屏并返回驿站截图，确认采集帧列表即可快速拼接高清长图。"
        ),
    ]
}
