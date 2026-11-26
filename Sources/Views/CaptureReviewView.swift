// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// Post-capture review: decodes captured PNG frames into a `StitchViewModel`, auto-suggests
/// fixed-bar cropping, and reuses the shared `StitchReviewView`.
struct CaptureReviewView: View {
    let frames: [Data]

    @StateObject private var model = StitchViewModel(autoSuggestCrop: true)
    @State private var isLoading = true
    @State private var didLoad = false

    var body: some View {
        Group {
            if isLoading {
                ProgressView("正在解码采集帧…")
            } else if model.images.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("没有可拼接的帧")
                        .font(.headline)
                    Text(model.errorMessage ?? "采集到的帧无法解码，请重新录制")
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
        .alert("加载失败", isPresented: $model.isShowingError, presenting: model.errorMessage) { _ in
            Button("好", role: .cancel) {}
        } message: { message in
            Text(message)
        }
        .task {
            guard !didLoad else { return }
            didLoad = true
            await model.loadAsync(pngFrames: frames)
            await model.suggestFixedBarCropAsync()
            isLoading = false
        }
    }
}
