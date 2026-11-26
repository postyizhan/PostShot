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

    @StateObject private var server = FrameBridgeServer()
    @StateObject private var keepAlive = AudioKeepAlive()
    @State private var showReview = false

    private let columns = [GridItem(.adaptive(minimum: 80), spacing: 8)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    BroadcastPickerButton(extensionBundleID: extensionBundleID)
                        .frame(width: 200, height: 80)
                    statusCard
                    if !server.receivedFrames.isEmpty {
                        stitchButton
                        frameGrid
                    }
                }
                .padding()
            }
            .navigationDestination(isPresented: $showReview) {
                CaptureReviewView(frames: server.receivedFrames)
            }
        }
        .onAppear { server.start(); keepAlive.start() }
        .onDisappear { server.stop(); keepAlive.stop() }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "record.circle")
                .font(.system(size: 44))
                .foregroundStyle(.red)
            Text("全屏录制长截图")
                .font(.headline)
            Text("点按钮开始录屏 → 选「驿站截图录制」→ 切到目标 App 匀速滚动 → 结束录屏后返回拼接")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
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
