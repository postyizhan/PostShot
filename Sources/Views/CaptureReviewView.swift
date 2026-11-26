// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// Post-capture review: selects sparse primary keyframes from `CaptureFrameStore` while retaining
/// the dense disk pool for automatic gap backfill, auto-detects fixed bars, and shares `StitchReviewView`.
struct CaptureReviewView: View {
    let store: CaptureFrameStore

    @StateObject private var model = StitchViewModel(autoSuggestCrop: true)
    @State private var isLoading = true
    @State private var didLoad = false

    var body: some View {
        Group {
            if isLoading {
                ProgressView("正在提取关键帧…")
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
            await model.loadFromStore(store)
            await model.suggestFixedBarCropAsync()
            isLoading = false
        }
    }
}
