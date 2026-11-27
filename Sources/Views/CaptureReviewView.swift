// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// Post-capture review: selects sparse primary keyframes from `CaptureFrameStore` while retaining
/// the dense disk pool for automatic gap backfill, auto-detects fixed bars, and enters `StitchEditorView`.
struct CaptureReviewView: View {
    let store: CaptureFrameStore

    @StateObject private var model = StitchViewModel(autoSuggestCrop: true)
    @State private var isLoading = true
    @State private var didLoad = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if isLoading {
                ProgressView("正在提取关键帧…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.systemGroupedBackground).ignoresSafeArea())
            } else if model.images.isEmpty {
                AppleEmptyStateView(
                    systemImage: "photo.badge.exclamationmark",
                    title: "没有可拼接的帧",
                    subtitle: model.errorMessage ?? "采集到的帧无法解码，请返回重新录制。",
                    tint: .orange
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground).ignoresSafeArea())
            } else {
                StitchEditorView(
                    model: model,
                    allowReselectPicker: false,
                    onClose: { dismiss() }
                )
            }
        }
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
