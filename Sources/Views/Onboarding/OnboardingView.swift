// SPDX-License-Identifier: AGPL-3.0-or-later
import Photos
import SwiftUI
import UIKit

/// 4-step progressive disclosure onboarding presented on first launch or from Settings.
struct OnboardingView: View {
    var onComplete: ((Int?) -> Void)? = nil

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    @State private var step = 0
    @State private var preferredTab: Int?
    @State private var photoStatus: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var justAuthorized = false
    @State private var tutorialMode: TutorialMode?

    var body: some View {
        VStack(spacing: 0) {
            OnboardingTopBar(
                step: step,
                totalSteps: 4,
                onBack: { moveStep(to: max(0, step - 1)) },
                onSkip: { finish(tab: preferredTab) }
            )
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(step)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .tint(DesignTokens.ink)
        .sheet(item: $tutorialMode) { GuideTutorialSheet(mode: $0) }
        .onAppear(perform: refreshPhotoStatus)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            refreshPhotoStatus()
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 0:
            OnboardingWelcomeStep(onStart: { moveStep(to: 1) }, onExplore: { finish(tab: nil) })
        case 1:
            OnboardingPermissionStep(
                photoStatus: photoStatus, justAuthorized: justAuthorized,
                onRequestAccess: requestPhotoAccess, onOpenSettings: openSystemSettings,
                onNext: { moveStep(to: 2) }, onRecordFallback: { preferredTab = 1; moveStep(to: 2) }
            )
        case 2:
            OnboardingHabitsStep(
                cleanupPolicy: $settings.originalCleanupPolicy,
                saveOnShare: $settings.saveStitchedOnShare,
                onNext: { moveStep(to: 3) }
            )
        default:
            OnboardingLearnStep(onSelectTutorial: { tutorialMode = $0 }, onFinish: { finish(tab: preferredTab) })
        }
    }

    private func moveStep(to target: Int) {
        withAnimation(AppleMotion.animation(AppleMotion.smooth, reduceMotion: reduceMotion)) { step = target }
    }

    private func refreshPhotoStatus() {
        photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    private func requestPhotoAccess() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            DispatchQueue.main.async {
                photoStatus = status
                guard status == .authorized || status == .limited else { return }
                withAnimation(AppleMotion.animation(AppleMotion.snappy, reduceMotion: reduceMotion)) {
                    justAuthorized = true
                }
            }
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    private func finish(tab: Int?) {
        settings.hasCompletedOnboarding = true
        onComplete?(tab)
        dismiss()
    }
}

// MARK: - Top Bar

private struct OnboardingTopBar: View {
    let step: Int
    let totalSteps: Int
    let onBack: () -> Void
    let onSkip: () -> Void

    var body: some View {
        HStack {
            if step > 0 {
                Button(action: onBack) {
                    Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary).frame(width: 34, height: 34)
                }
                .accessibilityLabel("上一步")
            } else {
                Spacer().frame(width: 34, height: 34)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<totalSteps, id: \.self) { index in
                    Capsule()
                        .fill(index <= step ? DesignTokens.ink : Color.primary.opacity(0.14))
                        .frame(width: index == step ? 22 : 7, height: 6)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("第 \(step + 1) 步，共 \(totalSteps) 步")
            Spacer()
            Button("跳过", action: onSkip)
                .font(.subheadline.weight(.medium)).foregroundStyle(.secondary).padding(.vertical, 6)
        }
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 4)
    }
}

private struct OnboardingStepShell<Content: View, Footer: View>: View {
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        GeometryReader { geo in
            ScrollView(showsIndicators: false) {
                content()
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .top)
                    .padding(.horizontal, 24)
            }
        }
        .safeAreaInset(edge: .bottom) {
            footer()
                .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 20)
                .background(Color(.systemGroupedBackground))
        }
    }
}

// MARK: - Step 0: Welcome

private struct OnboardingWelcomeStep: View {
    let onStart: () -> Void
    let onExplore: () -> Void

    var body: some View {
        OnboardingStepShell {
            VStack(spacing: 0) {
                Spacer(minLength: 16)
                OnboardingIllustrationView()
                Spacer(minLength: 20)
                VStack(spacing: 10) {
                    Text("驿站截图").font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("把多张截图拼成一张长图 · 开源免费 · 无广告")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                Spacer(minLength: 20)
            }
        } footer: {
            VStack(spacing: 8) {
                Button("开始使用", action: onStart).buttonStyle(ApplePrimaryButtonStyle())
                Button("我自己先探索", action: onExplore).buttonStyle(AppleGhostButtonStyle())
            }
        }
    }
}

// MARK: - Step 1: Photos Permission

private struct OnboardingPermissionStep: View {
    let photoStatus: PHAuthorizationStatus
    let justAuthorized: Bool
    let onRequestAccess: () -> Void
    let onOpenSettings: () -> Void
    let onNext: () -> Void
    let onRecordFallback: () -> Void

    private var isAuthorized: Bool { photoStatus == .authorized || photoStatus == .limited }

    var body: some View {
        OnboardingStepShell {
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 12)
                headerBlock
                Spacer(minLength: 18)
                VStack(spacing: 10) {
                    OnboardingIconCard(icon: "photo.stack", tint: DesignTokens.ink,
                                       title: "选取与保存截图", subtitle: "全部拼接均在本地完成，图片不会上传")
                    OnboardingIconCard(icon: "record.circle", tint: .red,
                                       title: "拒绝也可录屏拼接", subtitle: "滚动录屏模式无需读取系统相册即可抽帧拼合")
                }
                Spacer(minLength: 14)
                statusCard
                Spacer(minLength: 14)
            }
        } footer: {
            footerButtons
        }
    }

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(DesignTokens.ink)
                .frame(width: 56, height: 56)
                .background(DesignTokens.ink.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text("需要访问你的相册").font(.title.bold())
            Text("相册拼图与自动发现需要读取系统截图；若暂不授权，你仍可使用「滚动录屏」模式完成长截图。")
                .font(.subheadline).foregroundStyle(.secondary).lineSpacing(3)
        }
    }

    private var statusCard: some View {
        HStack(spacing: 10) {
            Label("相册状态：\(statusMeta.text)", systemImage: statusMeta.icon)
                .font(.subheadline.weight(.medium)).foregroundStyle(statusMeta.color)
            Spacer()
            if justAuthorized && isAuthorized {
                Label("已就绪", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(DesignTokens.success)
            } else if photoStatus == .denied || photoStatus == .restricted {
                Button("去系统设置", action: onOpenSettings)
                    .font(.caption.weight(.semibold)).foregroundStyle(.primary)
            }
        }
        .padding(14).appleCard(cornerRadius: 14)
    }

    private var statusMeta: (text: String, icon: String, color: Color) {
        switch photoStatus {
        case .authorized:          return ("已授权", "checkmark.circle.fill", DesignTokens.success)
        case .limited:             return ("部分授权", "checkmark.circle.fill", .primary)
        case .denied, .restricted: return ("已拒绝", "xmark.circle.fill", .red)
        default:                   return ("未授权", "questionmark.circle", .secondary)
        }
    }

    private var footerButtons: some View {
        VStack(spacing: 8) {
            if isAuthorized || photoStatus == .denied || photoStatus == .restricted {
                Button(isAuthorized ? "继续下一步" : "继续设置偏好", action: onNext)
                    .buttonStyle(ApplePrimaryButtonStyle())
            } else {
                Button("允许访问相册", action: onRequestAccess).buttonStyle(ApplePrimaryButtonStyle())
            }
            Button("暂不，使用录屏模式", action: onRecordFallback).buttonStyle(AppleGhostButtonStyle())
        }
    }
}

// MARK: - Step 2: Cleanup & Save Habits

private struct OnboardingHabitsStep: View {
    @Binding var cleanupPolicy: OriginalCleanupPolicy
    @Binding var saveOnShare: Bool
    let onNext: () -> Void

    var body: some View {
        OnboardingStepShell {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("清理与保存习惯").font(.title.bold())
                    Text("设定导出后的原图清理与分享保存策略").font(.subheadline).foregroundStyle(.secondary)
                }
                VStack(spacing: 8) {
                    ForEach(OriginalCleanupPolicy.allCases) { policy in
                        CleanupPolicyCard(policy: policy, isSelected: cleanupPolicy == policy) {
                            cleanupPolicy = policy
                        }
                    }
                }
                Text("说明：受 iOS PhotoKit 限制，清理相册原图时仅能移入系统「最近删除」并弹出系统确认；录屏临时帧缓存则会按所选策略立即清理。")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
                shareToggleCard
                Text("以上偏好随时可在「设置」中更改")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.top, 12).padding(.bottom, 16)
        } footer: {
            Button("下一步", action: onNext).buttonStyle(ApplePrimaryButtonStyle())
        }
    }

    private var shareToggleCard: some View {
        Toggle(isOn: $saveOnShare) {
            VStack(alignment: .leading, spacing: 3) {
                Text("分享长图时同时保存到相册").font(.subheadline.weight(.semibold))
                Text(saveOnShare ? "开启：分享时同步保存副本到相册" : "关闭：仅分享不留副本")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .tint(DesignTokens.toggleTint).padding(16).appleCard(cornerRadius: 16)
    }
}

private struct CleanupPolicyCard: View {
    let policy: OriginalCleanupPolicy
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20)).foregroundStyle(isSelected ? DesignTokens.ink : .secondary).padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(policy.displayName).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(policy.subtitle).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(14).appleCard(cornerRadius: 16)
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isSelected ? DesignTokens.ink : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Step 3: Learn How to Use

private struct OnboardingLearnStep: View {
    let onSelectTutorial: (TutorialMode) -> Void
    let onFinish: () -> Void

    var body: some View {
        OnboardingStepShell {
            VStack(spacing: 0) {
                Spacer(minLength: 16)
                VStack(spacing: 8) {
                    Text("想学习一下如何使用吗？").font(.title2.bold()).multilineTextAlignment(.center)
                    Text("按你的习惯挑一种方式了解，也可随时在设置中重温")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(.horizontal, 12)
                Spacer(minLength: 24)
                VStack(spacing: 12) {
                    ForEach(TutorialMode.allCases) { mode in
                        Button { onSelectTutorial(mode) } label: {
                            OnboardingIconCard(icon: mode.icon, tint: mode.tint,
                                               title: mode.title, subtitle: mode.subtitle, showChevron: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer(minLength: 16)
            }
        } footer: {
            Button("进入驿站截图", action: onFinish).buttonStyle(ApplePrimaryButtonStyle())
        }
    }
}

private struct OnboardingIconCard: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    var showChevron = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 19, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if showChevron {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .padding(14).appleCard(cornerRadius: 16)
    }
}
