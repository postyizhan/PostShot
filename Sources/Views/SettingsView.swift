// SPDX-License-Identifier: AGPL-3.0-or-later
import Photos
import SwiftUI
import UIKit

/// Unified settings sheet accessible from every tab's navigation bar.
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var bridgeServer: FrameBridgeServer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var photoStatus: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var showOnboarding = false
    @State private var showAlbumPicker = false
    @State private var tutorialMode: TutorialMode?

    private static let delayOptions = [0, 1, 2, 3, 5]
    private static let idleOptions = [2, 3, 5, 8]

    var body: some View {
        NavigationStack {
            List {
                permissionsSection
                exportDefaultsSection
                cleanupAndShareSection
                recordingSection
                feedbackSection
                guidanceSection
                diagnosticsAndAboutSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                        .font(.body.weight(.semibold))
                }
            }
            .fullScreenCover(isPresented: $showOnboarding) {
                OnboardingView()
                    .environmentObject(settings)
            }
            .sheet(item: $tutorialMode) { mode in
                GuideTutorialSheet(mode: mode)
            }
            .sheet(isPresented: $showAlbumPicker) {
                AlbumPickerSheet(selectedAlbumName: $settings.targetAlbumName)
            }
            .onAppear(perform: refreshPhotoStatus)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                refreshPhotoStatus()
            }
        }
    }

    // MARK: - 1. Permissions

    private var permissionsSection: some View {
        Section("权限与访问") {
            LabeledContent {
                Text(photoStatusText)
                    .foregroundStyle(photoStatusColor)
            } label: {
                SettingsRowLabel(title: "相册权限", systemImage: "photo.fill", color: .blue)
            }

            Button {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                openURL(url)
            } label: {
                HStack {
                    SettingsRowLabel(title: "前往系统设置", systemImage: "gearshape.fill", color: .gray)
                    Spacer()
                    Image(systemName: "arrow.up.forward.app")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.primary)
        }
    }

    // MARK: - 2. Export Defaults

    private var exportDefaultsSection: some View {
        Section("导出默认设置") {
            Picker(selection: $settings.defaultExportFormat) {
                ForEach(ExportFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            } label: {
                SettingsRowLabel(title: "默认格式", systemImage: "doc.richtext.fill", color: .indigo)
            }

            exportQualityRow

            Picker(selection: $settings.exportDPI) {
                ForEach(ExportDPI.allCases) { dpi in
                    Text(dpi.displayName).tag(dpi)
                }
            } label: {
                SettingsRowLabel(title: "导出分辨率", systemImage: "dial.medium.fill", color: .teal)
            }

            Button { showAlbumPicker = true } label: {
                HStack {
                    SettingsRowLabel(title: "默认保存相册", systemImage: "rectangle.stack.fill", color: .cyan)
                    Spacer()
                    Text(settings.targetAlbumDisplayName)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.primary)

            Toggle(isOn: $settings.removeScrollIndicatorByDefault) {
                SettingsRowLabel(
                    title: "自动去除右侧滚动条",
                    systemImage: "arrow.up.and.down.text.horizontal",
                    color: .teal
                )
            }
            .tint(DesignTokens.accentBlue)
        }
    }

    private var exportQualityRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SettingsRowLabel(title: "图片质量", systemImage: "slider.horizontal.3", color: .purple)
                Spacer()
                Text(qualityValueText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $settings.exportQuality, in: 0.1...1.0, step: 0.05)
                .disabled(!settings.defaultExportFormat.supportsQuality)
                .tint(DesignTokens.accentBlue)
        }
        .padding(.vertical, 2)
    }

    // MARK: - 3. Share & Cleanup

    private var cleanupAndShareSection: some View {
        Section {
            Picker(selection: $settings.originalCleanupPolicy) {
                ForEach(OriginalCleanupPolicy.allCases) { policy in
                    Text(policy.displayName).tag(policy)
                }
            } label: {
                SettingsRowLabel(title: "原图清理策略", systemImage: "trash.fill", color: .orange)
            }

            Toggle(isOn: $settings.saveStitchedOnShare) {
                SettingsRowLabel(title: "分享后同时保存到相册", systemImage: "square.and.arrow.up.fill", color: .green)
            }
            .tint(DesignTokens.accentBlue)
        } header: {
            Text("分享与清理策略")
        } footer: {
            Text(settings.originalCleanupPolicy.subtitle)
        }
    }

    // MARK: - 4. Recording

    private var recordingSection: some View {
        Section {
            Toggle(isOn: $bridgeServer.waitForAppSwitch) {
                SettingsRowLabel(title: "切出本软件后自动开录", systemImage: "arrow.triangle.2.circlepath", color: .red)
            }
            .tint(DesignTokens.accentBlue)

            Picker(selection: $bridgeServer.extraDelaySeconds) {
                ForEach(Self.delayOptions, id: \.self) { sec in
                    Text(sec == 0 ? "无延迟" : "\(sec) 秒").tag(sec)
                }
            } label: {
                SettingsRowLabel(title: "开录缓冲延迟", systemImage: "timer", color: .pink)
            }

            Toggle(isOn: $settings.autoStopOnScrollIdle) {
                SettingsRowLabel(title: "停止滚动后自动结束", systemImage: "hand.raised.fill", color: .orange)
            }
            .tint(DesignTokens.accentBlue)

            if settings.autoStopOnScrollIdle {
                idleStopDurationRow
            }
        } header: {
            Text("滚动录屏设置")
        }
    }

    private var idleStopDurationRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(selection: $settings.scrollIdleStopSeconds) {
                ForEach(Self.idleOptions, id: \.self) { sec in
                    Text("\(sec) 秒").tag(sec)
                }
            } label: {
                SettingsRowLabel(title: "停滑等待时长", systemImage: "hourglass", color: .yellow)
            }
            Text("UI 已就绪 · 停滑自动停录检测将在后续版本接入")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 38)
        }
    }

    // MARK: - 5. Feedback

    private var feedbackSection: some View {
        Section("交互与反馈") {
            Toggle(isOn: $settings.soundEnabled) {
                SettingsRowLabel(title: "界面轻音效", systemImage: "speaker.wave.2.fill", color: .blue)
            }
            .tint(DesignTokens.accentBlue)

            Toggle(isOn: $settings.hapticsEnabled) {
                SettingsRowLabel(title: "触觉反馈", systemImage: "waveform", color: .mint)
            }
            .tint(DesignTokens.accentBlue)
        }
    }

    // MARK: - 6. Guidance

    private var guidanceSection: some View {
        Section("引导与教程") {
            Button { showOnboarding = true } label: {
                SettingsRowLabel(title: "重新进入新手引导", systemImage: "sparkles", color: .blue)
            }
            .foregroundStyle(.primary)

            ForEach(TutorialMode.allCases) { mode in
                Button { tutorialMode = mode } label: {
                    HStack {
                        SettingsRowLabel(title: "\(mode.title)教程", systemImage: mode.icon, color: mode.tint)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.primary)
            }
        }
    }

    // MARK: - 7. Diagnostics & About

    private var diagnosticsAndAboutSection: some View {
        Section("诊断与关于") {
            NavigationLink {
                RecordingDiagnosticsView()
            } label: {
                SettingsRowLabel(title: "录制连接诊断", systemImage: "stethoscope", color: .gray)
            }

            LabeledContent {
                Text(appVersion)
                    .foregroundStyle(.secondary)
            } label: {
                SettingsRowLabel(title: "版本", systemImage: "info.circle.fill", color: .blue)
            }

            NavigationLink {
                LicenseDetailView()
            } label: {
                SettingsRowLabel(title: "开源许可证", systemImage: "doc.text.fill", color: .secondary)
            }
        }
    }

    // MARK: - Helpers

    private func refreshPhotoStatus() {
        photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    private var qualityValueText: String {
        guard settings.defaultExportFormat.supportsQuality else { return "无损 100%" }
        return "\(Int((settings.exportQuality * 100).rounded()))%"
    }

    private var photoStatusText: String {
        switch photoStatus {
        case .authorized:           return "已授权"
        case .limited:              return "部分授权"
        case .denied, .restricted:  return "已拒绝"
        default:                    return "未授权"
        }
    }

    private var photoStatusColor: Color {
        switch photoStatus {
        case .authorized:           return DesignTokens.success
        case .limited:              return DesignTokens.accentBlue
        case .denied, .restricted:  return .red
        default:                    return .secondary
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }
}

// MARK: - Helper Subviews

private struct SettingsRowLabel: View {
    let title: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            SettingsIconBadge(systemImage: systemImage, color: color)
            Text(title)
        }
    }
}

private struct RecordingDiagnosticsView: View {
    @EnvironmentObject private var bridgeServer: FrameBridgeServer

    var body: some View {
        List {
            Section("本地回环桥接状态") {
                LabeledContent("监听状态", value: bridgeServer.status)
                LabeledContent("已采集帧数", value: "\(bridgeServer.frameCount)")
                LabeledContent("最后控制消息", value: bridgeServer.lastControl)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("录制连接诊断")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LicenseDetailView: View {
    var body: some View {
        ScrollView {
            Text("""
            PostShot 驿站截图
            Copyright © 2026 PostShot contributors

            This program is free software: you can redistribute it and/or modify \
            it under the terms of the GNU Affero General Public License as published by \
            the Free Software Foundation, either version 3 of the License, or \
            (at your option) any later version.

            This program is distributed in the hope that it will be useful, \
            but WITHOUT ANY WARRANTY; without even the implied warranty of \
            MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the \
            GNU Affero General Public License for more details.

            Source code: https://github.com/PostShot/PostShot
            License: GNU AGPL-3.0-or-later
            """)
            .font(.caption.monospaced())
            .padding()
        }
        .navigationTitle("开源许可证")
        .navigationBarTitleDisplayMode(.inline)
    }
}
