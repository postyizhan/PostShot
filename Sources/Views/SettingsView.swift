// SPDX-License-Identifier: AGPL-3.0-or-later
import Photos
import SwiftUI
import UIKit

/// Pure-typography Apple-native settings sheet accessible from every tab.
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
        .tint(DesignTokens.ink)
    }

    // MARK: - 1. Permissions

    private var permissionsSection: some View {
        Section("权限与访问") {
            LabeledContent("相册权限") {
                Text(photoStatusText)
                    .foregroundStyle(photoStatusColor)
            }

            Button {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                openURL(url)
            } label: {
                HStack {
                    Text("前往系统设置")
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
            Picker("默认格式", selection: $settings.defaultExportFormat) {
                ForEach(ExportFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .tint(.secondary)

            if settings.defaultExportFormat.supportsQuality {
                exportQualityRow
            }

            Button { showAlbumPicker = true } label: {
                HStack {
                    Text("默认保存相册")
                    Spacer()
                    Text(settings.targetAlbumDisplayName)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.primary)

            Toggle("自动去除右侧滚动条", isOn: $settings.removeScrollIndicatorByDefault)
                .tint(DesignTokens.toggleTint)
        }
    }

    private var exportQualityRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("图片质量")
                Spacer()
                Text("\(Int((settings.exportQuality * 100).rounded()))%")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $settings.exportQuality, in: 0.1...1.0, step: 0.05)
                .tint(DesignTokens.ink)
        }
        .padding(.vertical, 2)
    }

    // MARK: - 3. Share & Cleanup

    private var cleanupAndShareSection: some View {
        Section {
            Picker("原图清理策略", selection: $settings.originalCleanupPolicy) {
                ForEach(OriginalCleanupPolicy.allCases) { policy in
                    Text(policy.displayName).tag(policy)
                }
            }
            .tint(.secondary)

            Toggle("分享后同时保存到相册", isOn: $settings.saveStitchedOnShare)
                .tint(DesignTokens.toggleTint)
        } header: {
            Text("分享与清理策略")
        } footer: {
            Text(settings.originalCleanupPolicy.subtitle)
        }
    }

    // MARK: - 4. Recording

    private var recordingSection: some View {
        Section("滚动录屏设置") {
            Toggle("切出本软件后自动开录", isOn: $bridgeServer.waitForAppSwitch)
                .tint(DesignTokens.toggleTint)

            Picker("开录缓冲延迟", selection: $bridgeServer.extraDelaySeconds) {
                ForEach(Self.delayOptions, id: \.self) { sec in
                    Text(sec == 0 ? "无延迟" : "\(sec) 秒").tag(sec)
                }
            }
            .tint(.secondary)
        }
    }

    // MARK: - 5. Feedback

    private var feedbackSection: some View {
        Section("交互与反馈") {
            Toggle("界面轻音效", isOn: $settings.soundEnabled)
                .tint(DesignTokens.toggleTint)

            Toggle("触觉反馈", isOn: $settings.hapticsEnabled)
                .tint(DesignTokens.toggleTint)
        }
    }

    // MARK: - 6. Guidance

    private var guidanceSection: some View {
        Section("引导与教程") {
            Button("重新查看新手引导") { showOnboarding = true }
                .foregroundStyle(.primary)

            ForEach(TutorialMode.allCases) { mode in
                Button { tutorialMode = mode } label: {
                    HStack {
                        Text("\(mode.title)教程")
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
            NavigationLink("录制连接诊断") {
                RecordingDiagnosticsView()
            }

            LabeledContent("版本") {
                Text(appVersion)
                    .foregroundStyle(.secondary)
            }

            NavigationLink("开源许可证") {
                LicenseDetailView()
            }
        }
    }

    // MARK: - Helpers

    private func refreshPhotoStatus() {
        photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
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
        case .limited:              return .primary
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
