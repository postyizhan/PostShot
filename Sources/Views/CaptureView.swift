// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import UIKit

/// Screen-recording capture screen: receives sparse PNG keyframes over the loopback TCP bridge
/// while `AudioKeepAlive` prevents iOS from suspending the host app in the background.
struct CaptureView: View {
    private var extensionBundleID: String {
        "\(Bundle.main.bundleIdentifier ?? "com.postshot.app").broadcast"
    }

    @ObservedObject var server: FrameBridgeServer
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showReview = false
    @State private var showDiagnostics = false
    @State private var showSettings = false
    @State private var showTutorial = false
    @State private var previewIndex: Int?
    @State private var pulseActive = false

    private let columns = [GridItem(.adaptive(minimum: 84), spacing: 10)]

    var body: some View {
        NavigationStack {
            studioScrollContent
                .background(Color(.systemGroupedBackground).ignoresSafeArea())
                .navigationTitle("全屏录制")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button { showDiagnostics = true } label: {
                            Image(systemName: "waveform.path.ecg").foregroundStyle(DesignTokens.accentBlue)
                        }
                        .accessibilityLabel("录制诊断")
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape").foregroundStyle(DesignTokens.accentBlue)
                        }
                        .accessibilityLabel("设置")
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { showTutorial = true } label: {
                            Image(systemName: "questionmark.circle").foregroundStyle(DesignTokens.accentBlue)
                        }
                        .accessibilityLabel("使用教程")
                    }
                }
                .navigationDestination(isPresented: $showReview) {
                    CaptureReviewView(store: server.frameStore).environmentObject(settings)
                }
                .sheet(isPresented: $showSettings) { SettingsView().environmentObject(settings) }
                .sheet(isPresented: $showTutorial) { GuideTutorialSheet(mode: .record) }
                .sheet(isPresented: $showDiagnostics) { diagnosticsSheet }
                .sheet(item: previewSheetBinding) { item in
                    SingleImagePreviewView(
                        initialIndex: item.index,
                        images: server.previews.map { SelectedImage(cgImage: blankCGImage(), thumbnail: $0.thumbnail) }
                    )
                }
        }
        .onChange(of: server.frameCount > 0) { pulseActive = $0 && !reduceMotion }
        .onAppear { pulseActive = server.frameCount > 0 && !reduceMotion }
    }

    private var studioScrollContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                recordHeader
                broadcastPickerCard
                recordingSettingsCard
                if server.isFinished { finishedBanner }
                if server.frameCount > 0 {
                    stitchButton
                    frameGrid
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private var previewSheetBinding: Binding<PreviewItem?> {
        Binding(
            get: { previewIndex.map { PreviewItem(index: $0) } },
            set: { previewIndex = $0?.index }
        )
    }

    // MARK: - Recording Studio Header

    private var recordHeader: some View {
        let isCapturing = server.frameCount > 0
        let ringColor: Color = isCapturing ? .red : DesignTokens.accentBlue

        return VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(ringColor.opacity(isCapturing ? 0.14 : 0.10))
                    .frame(width: 92, height: 92)
                    .scaleEffect(pulseActive ? 1.12 : 1.0)
                    .animation(
                        pulseActive
                            ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                            : .default,
                        value: pulseActive
                    )

                Circle()
                    .strokeBorder(ringColor.opacity(isCapturing ? 0.45 : 0.22), lineWidth: 2)
                    .frame(width: 74, height: 74)

                Image(systemName: isCapturing ? "record.circle.fill" : "record.circle")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(ringColor)
            }

            Text(isCapturing ? "录制采集中 · \(server.frameCount) 帧" : "全屏滚动录制")
                .font(.title3.weight(.semibold))

            Text(server.status)
                .capsuleLabelStyle(tint: isCapturing ? .red : DesignTokens.accentBlue)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - Broadcast Picker Card

    private var broadcastPickerCard: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(DesignTokens.accentBlue.opacity(0.10))
                    .frame(width: 84, height: 84)
                BroadcastPickerButton(extensionBundleID: extensionBundleID)
                    .frame(width: 200, height: 80)
            }

            HStack(spacing: 6) {
                stepBadge("1. 开启录制")
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                stepBadge("2. 切换滚动")
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                stepBadge("3. 停录拼接")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .appleCard()
    }

    private func stepBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color(.tertiarySystemGroupedBackground), in: Capsule())
    }

    // MARK: - Recording Settings Card

    private var recordingSettingsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("录制设置")
                .font(.subheadline.weight(.semibold))

            Toggle("切出本软件后自动开录", isOn: $server.waitForAppSwitch)
                .font(.subheadline)

            VStack(alignment: .leading, spacing: 6) {
                Text("缓冲延迟")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("缓冲延迟", selection: $server.extraDelaySeconds) {
                    Text("立即").tag(0)
                    Text("+1s").tag(1)
                    Text("+2s").tag(2)
                    Text("+3s").tag(3)
                    Text("+5s").tag(5)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Divider()

            Toggle("停止滚动后自动结束", isOn: $settings.autoStopOnScrollIdle)
                .font(.subheadline)

            if settings.autoStopOnScrollIdle {
                VStack(alignment: .leading, spacing: 6) {
                    Text("静止等待时长")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("静止等待时长", selection: $settings.scrollIdleStopSeconds) {
                        Text("2秒").tag(2)
                        Text("3秒").tag(3)
                        Text("5秒").tag(5)
                        Text("8秒").tag(8)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Text("UI 已就绪 · 停滑自动停录检测将在后续版本接入")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .appleCard()
        .appleAnimation(AppleMotion.snappy, value: settings.autoStopOnScrollIdle)
    }

    // MARK: - Finished Banner & Frame Grid

    private var finishedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(DesignTokens.success)
            Text("录制结束，共 \(server.frameCount) 帧")
                .font(.subheadline.weight(.medium))
            Spacer()
            Button("清空重录") {
                server.reset()
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(DesignTokens.success.opacity(0.14), in: Capsule())
            .foregroundStyle(DesignTokens.success)
        }
        .padding(14)
        .background(DesignTokens.success.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(DesignTokens.success.opacity(0.22), lineWidth: 1)
        )
    }

    private var stitchButton: some View {
        Button {
            showReview = true
        } label: {
            Label("进入编辑器拼接 (\(server.frameCount) 帧)", systemImage: "arrow.down.to.line.compact")
        }
        .buttonStyle(ApplePrimaryButtonStyle())
        .disabled(server.frameCount < 2)
    }

    private var frameGrid: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(Array(server.previews.enumerated()), id: \.element.id) { index, item in
                Button {
                    previewIndex = index
                } label: {
                    Image(uiImage: item.thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 144)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(alignment: .topLeading) {
                            Text("\(index + 1)")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(6)
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Diagnostics Sheet

    private var diagnosticsSheet: some View {
        NavigationStack {
            List {
                Section("连接状态") {
                    LabeledContent("状态", value: server.status)
                    LabeledContent("已采帧", value: "\(server.frameCount)")
                    LabeledContent("最后消息", value: server.lastControl)
                }
            }
            .navigationTitle("录制诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { showDiagnostics = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func blankCGImage() -> CGImage {
        let ctx = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }
}

private struct PreviewItem: Identifiable {
    let index: Int
    var id: Int { index }
}
