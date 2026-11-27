// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import UIKit

/// Screen-recording capture screen: receives sparse PNG keyframes over the loopback TCP bridge
/// while `AudioKeepAlive` prevents iOS from suspending the host app in the background, then
/// navigates into the shared review/stitch flow.
struct CaptureView: View {
    private var extensionBundleID: String {
        "\(Bundle.main.bundleIdentifier ?? "com.postshot.app").broadcast"
    }

    @ObservedObject var server: FrameBridgeServer
    @State private var showReview = false

    private let columns = [GridItem(.adaptive(minimum: 80), spacing: 8)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    BroadcastPickerButton(extensionBundleID: extensionBundleID)
                        .frame(width: 200, height: 80)
                    startSettingsCard
                    statusCard
                    if server.frameCount > 0 {
                        stitchButton
                        frameGrid
                    }
                }
                .padding()
            }
            .navigationDestination(isPresented: $showReview) {
                CaptureReviewView(store: server.frameStore)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "record.circle")
                .font(.system(size: 44))
                .foregroundStyle(.red)
            Text("全屏录制长截图")
                .font(.headline)
            Text("开始直播后系统有 3 秒倒计时 → 听到轻提示音或灵动岛变红后再开始滚动 → 结束录屏返回拼接")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var startSettingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("录制启动设置").font(.subheadline.bold())
            Toggle("切出本软件后自动开录", isOn: $server.waitForAppSwitch)
                .font(.subheadline)
            VStack(alignment: .leading, spacing: 6) {
                Text("开录缓冲延迟")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("开录缓冲延迟", selection: $server.extraDelaySeconds) {
                    Text("立即(0s)").tag(0)
                    Text("+1s").tag(1)
                    Text("+2s").tag(2)
                    Text("+3s").tag(3)
                    Text("+5s").tag(5)
                }
                .pickerStyle(.segmented)
            }
            Text("注：iOS 系统直播固定先倒数 3 秒；开启上方选项后，会自动等你切入目标 App 并度过缓冲时间后再响提示音开始采帧。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("采集状态").font(.subheadline.bold())
            row("监听状态", server.status)
            row("收到关键帧", "\(server.frameCount)")
            row("最后控制消息", server.lastControl)
            if server.isFinished {
                Text("✅ 录制结束，共采集 \(server.frameCount) 张关键帧，点击「去拼接」审阅生成长图")
                    .font(.caption).foregroundStyle(.green)
            }
            if server.frameCount > 0 {
                Button("清空重录") { server.reset() }
                    .font(.caption)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var stitchButton: some View {
        Button {
            showReview = true
        } label: {
            Label("去拼接(\(server.frameCount) 帧)", systemImage: "arrow.down.to.line.compact")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(server.frameCount < 2)
    }

    private var frameGrid: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Array(server.previews.enumerated()), id: \.element.id) { index, item in
                Image(uiImage: item.thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 80, height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .topLeading) {
                        Text("\(index + 1)")
                            .font(.caption2.bold())
                            .padding(3)
                            .background(.black.opacity(0.6), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(4)
                    }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption)
            Spacer()
            Text(value).font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
