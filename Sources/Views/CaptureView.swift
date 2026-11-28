// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import UIKit

/// Pure screen-recording studio tab: single unambiguous broadcast trigger,
/// live capture summary row, and collected frame grid.
struct CaptureView: View {
    private var extensionBundleID: String {
        "\(Bundle.main.bundleIdentifier ?? "com.postshot.app").broadcast"
    }

    @ObservedObject var server: FrameBridgeServer
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showReview = false
    @State private var showSettings = false
    @State private var previewIndex: Int?
    @State private var pulseActive = false

    private let columns = [GridItem(.adaptive(minimum: 84), spacing: 10)]

    var body: some View {
        NavigationStack {
            studioScrollContent
                .background(Color(.systemGroupedBackground).ignoresSafeArea())
                .navigationTitle("录制")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape")
                                .foregroundStyle(.primary)
                        }
                        .accessibilityLabel("设置")
                    }
                }
                .navigationDestination(isPresented: $showReview) {
                    CaptureReviewView(store: server.frameStore).environmentObject(settings)
                }
                .sheet(isPresented: $showSettings) {
                    SettingsView().environmentObject(settings)
                }
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
                recordTriggerCard
                capturePolicyRow
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

    // MARK: - Single Recording Trigger

    private var recordTriggerCard: some View {
        let isCapturing = server.frameCount > 0
        let ringColor: Color = isCapturing ? .red : .primary

        return VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(ringColor.opacity(isCapturing ? 0.14 : 0.06))
                    .frame(width: 108, height: 108)
                    .scaleEffect(pulseActive ? 1.12 : 1.0)
                    .animation(
                        pulseActive
                            ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                            : .default,
                        value: pulseActive
                    )
                    .allowsHitTesting(false)

                Circle()
                    .strokeBorder(ringColor.opacity(isCapturing ? 0.45 : 0.14), lineWidth: 1.5)
                    .frame(width: 88, height: 88)
                    .allowsHitTesting(false)

                BroadcastPickerButton(
                    extensionBundleID: extensionBundleID,
                    isCapturing: isCapturing
                )
                .frame(width: 88, height: 88)
            }
            .padding(.top, 4)

            VStack(spacing: 8) {
                Text(isCapturing ? "正在采集 · \(server.frameCount) 帧" : "滚动录屏")
                    .font(.title3.weight(.semibold))

                Text(server.status)
                    .capsuleLabelStyle(tint: isCapturing ? .red : .secondary)
                    .multilineTextAlignment(.center)

                Text("开启录制 · 切出页面滚动 · 停录拼接")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 18)
        .appleCard()
    }

    // MARK: - Compact Policy Summary Row

    private var capturePolicyRow: some View {
        Button { showSettings = true } label: {
            HStack(spacing: 12) {
                Text("录屏行为")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(capturePolicySummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .appleCard(cornerRadius: 16)
        }
        .buttonStyle(.plain)
    }

    private var capturePolicySummary: String {
        let modeText = server.waitForAppSwitch ? "切出自动开录" : "立即开录"
        if server.extraDelaySeconds > 0 {
            return "\(modeText) · +\(server.extraDelaySeconds)s"
        }
        return modeText
    }

    // MARK: - Finished Banner & Frame Grid

    private var finishedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(DesignTokens.success)
            Text("录制完成，共 \(server.frameCount) 帧")
                .font(.subheadline.weight(.medium))
            Spacer()
            Button("重录") {
                server.reset()
            }
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(DesignTokens.inkSubtle, in: Capsule())
            .foregroundStyle(.primary)
        }
        .padding(14)
        .appleCard(cornerRadius: 16)
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
                    Color(.tertiarySystemGroupedBackground)
                        .frame(height: 144)
                        .overlay {
                            Image(uiImage: item.thumbnail)
                                .resizable()
                                .scaledToFill()
                        }
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
