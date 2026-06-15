// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// Phase 0 capture + diagnostics screen. Launches a screen broadcast, then surfaces enough
/// detail to pinpoint WHY frames may not arrive: the app's own App-Group health, and what the
/// extension reported. Comparing the two container paths reveals whether 爱思/AltStore rewrote
/// the group id inconsistently between app and extension (the prime suspect when a broadcast
/// runs but no frames show up).
struct CaptureView: View {
    private let extensionBundleID = "com.postshot.app.broadcast"
    private let suite = "group.com.postshot.app"

    @State private var report = AppGroupDiagnostics.run()
    @State private var frameCount = 0
    @State private var frameFilesOnDisk = 0
    @State private var extContainerPath = "(尚无)"
    @State private var extWriteResult = "(尚无)"
    @State private var extPhase = "(尚无)"

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                broadcastControl
                appGroupCard
                extensionCard
                Button("刷新状态") { refresh() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .onAppear(perform: refresh)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "record.circle")
                .font(.system(size: 44))
                .foregroundStyle(.red)
            Text("全屏录制(实验)")
                .font(.headline)
            Text("点下方按钮开始录屏 → 切到目标 App 缓慢滚动 → 回控制中心停止 → 回来刷新状态")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var broadcastControl: some View {
        BroadcastPickerButton(extensionBundleID: extensionBundleID)
            .frame(width: 200, height: 80)
    }

    private var appGroupCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("① 主 App 的 App Group 自检").font(.subheadline.bold())
            row("容器可用", report.containerAvailable ? "是 ✅" : "否 ❌")
            row("读写测试", report.writeReadOK ? "通过 ✅" : "失败 ❌")
            Text("容器路径:\(report.containerPath)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Text(report.detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var extensionCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("② 扩展上报(经 App Group 回传)").font(.subheadline.bold())
            row("收到帧数", "\(frameCount)")
            row("落盘帧文件", "\(frameFilesOnDisk)")
            row("写帧结果", extWriteResult)
            row("扩展阶段", extPhase)
            Text("扩展看到的容器:\(extContainerPath)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(3)
            if extContainerPath != "(尚无)" && extContainerPath != report.containerPath {
                Text("⚠️ 两端容器路径不一致 → 签名时 App Group 被改写得不匹配,这就是收不到帧的原因")
                    .font(.caption).foregroundStyle(.orange)
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
            Text(value).font(.caption.monospaced())
        }
    }

    private func refresh() {
        report = AppGroupDiagnostics.run()
        frameFilesOnDisk = FrameStore.frameCount()
        if let defaults = UserDefaults(suiteName: suite) {
            frameCount = defaults.integer(forKey: "lastBroadcastFrameCount")
            extContainerPath = defaults.string(forKey: "extContainerPath") ?? "(尚无)"
            extWriteResult = defaults.string(forKey: "extWriteResult") ?? "(尚无)"
            extPhase = defaults.string(forKey: "extPhase") ?? "(尚无)"
        }
    }
}
