// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// Phase 0 (attempt 2) capture screen: tests the loopback SOCKET bridge instead of App Group.
///
/// TEST PROTOCOL: tap record, pick 驿站截图录制, then STAY on this screen (do not switch apps).
/// The extension connects to the listener below and streams text messages. If "收到消息" climbs
/// while recording, the extension→app socket channel works without an App Group.
struct CaptureView: View {
    private let extensionBundleID = "com.postshot.app.broadcast"

    @StateObject private var server = FrameBridgeServer()

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                BroadcastPickerButton(extensionBundleID: extensionBundleID)
                    .frame(width: 200, height: 80)
                bridgeCard
            }
            .padding()
        }
        .onAppear { server.start() }
        .onDisappear { server.stop() }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "record.circle")
                .font(.system(size: 44))
                .foregroundStyle(.red)
            Text("全屏录制(socket 验证)")
                .font(.headline)
            Text("点按钮开始录屏 → 选「驿站截图录制」→ 留在本页别切走 → 看下方消息是否增长")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var bridgeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Socket 桥状态").font(.subheadline.bold())
            row("监听状态", server.status)
            row("收到消息", "\(server.messageCount)")
            Text("最后一条:\(server.lastMessage)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if server.messageCount > 0 {
                Text("✅ 扩展已通过 socket 连上主 App —— App Group 障碍绕过成功")
                    .font(.caption).foregroundStyle(.green)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption)
            Spacer()
            Text(value).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }
}
