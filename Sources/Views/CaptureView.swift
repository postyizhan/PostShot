// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// Phase 0 capture screen: launch a screen broadcast, then show how many frames the
/// extension received and whether it managed to hand one back through the App Group.
///
/// This is the sideload smoke test made visible — if "已收到 N 帧" updates after a
/// recording, the extension + App Group round-trip works on a free-signed install.
struct CaptureView: View {
    private let extensionBundleID = "com.postshot.app.broadcast"

    @State private var frameCount = 0
    @State private var hasProbeFrame = false

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: "record.circle")
                    .font(.system(size: 48))
                    .foregroundStyle(.red)
                Text("全屏录制(实验)")
                    .font(.headline)
                Text("点下方按钮开始录屏,切到要长截图的 App 缓慢滚动一遍,再回来停止。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            BroadcastPickerButton(extensionBundleID: extensionBundleID)
                .frame(width: 200, height: 80)

            VStack(spacing: 6) {
                Text("上次录制收到:\(frameCount) 帧")
                    .font(.subheadline.monospacedDigit())
                Label(
                    hasProbeFrame ? "已通过 App Group 收到帧 ✅" : "尚未收到帧",
                    systemImage: hasProbeFrame ? "checkmark.seal.fill" : "hourglass"
                )
                .font(.footnote)
                .foregroundStyle(hasProbeFrame ? .green : .secondary)
            }

            Button("刷新状态") { refresh() }
                .buttonStyle(.bordered)
        }
        .padding()
        .onAppear(perform: refresh)
    }

    private func refresh() {
        if let defaults = UserDefaults(suiteName: "group.com.postshot.app") {
            frameCount = defaults.integer(forKey: "lastBroadcastFrameCount")
        }
        hasProbeFrame = FrameStore.frameCount() > 0
    }
}
