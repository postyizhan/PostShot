// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import UIKit

/// v2 capture screen: real frame pipeline over the loopback socket bridge, then "去拼接" navigates
/// into the shared review/stitch flow (Phase 2).
///
/// TEST PROTOCOL: tap record, pick 驿站截图录制, then STAY on this screen (do not switch apps) and
/// slowly scroll the content you want captured. The extension extracts keyframes, encodes PNG, and
/// streams them here. A handful of sparse thumbnails (not hundreds) means FrameSelector + transport
/// work; tap 去拼接 to review and stitch them into one long image.
struct CaptureView: View {
    private let extensionBundleID = "com.postshot.app.broadcast"

    @StateObject private var server = FrameBridgeServer()
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
        .onAppear { server.start() }
        .onDisappear { server.stop() }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "record.circle")
                .font(.system(size: 44))
                .foregroundStyle(.red)
            Text("全屏录制(真实帧采集)")
                .font(.headline)
            Text("点按钮开始录屏 → 选「驿站截图录制」→ 留在本页别切走 → 缓慢滚动要截的内容")
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
                Text("✅ 录制结束,共采集 \(server.frameCount) 张关键帧(拼接为 Phase 2)")
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
            ForEach(Array(server.receivedFrames.enumerated()), id: \.offset) { index, png in
                if let image = UIImage(data: png) {
                    Image(uiImage: image)
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
