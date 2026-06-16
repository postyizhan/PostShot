// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// v2 post-capture review (Phase 2): seeds a `StitchViewModel` from the captured PNG frames, then
/// reuses the exact same `StitchReviewView` as the v1 PhotosPicker flow — strip (delete junk
/// frames), manual crop, stitch, preview. The only v2-specific part is the frame source.
struct CaptureReviewView: View {
    let frames: [Data]

    @StateObject private var model = StitchViewModel()
    @State private var didLoad = false

    var body: some View {
        Group {
            if model.images.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("没有可拼接的帧")
                        .font(.headline)
                    Text("采集到的帧无法解码,请重新录制")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                StitchReviewView(model: model)
            }
        }
        .navigationTitle("审阅采集帧")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Decode once; @StateObject persists across re-renders.
            guard !didLoad else { return }
            didLoad = true
            model.load(pngFrames: frames)
        }
    }
}
