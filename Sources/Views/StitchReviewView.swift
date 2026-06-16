// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// Shared "review and stitch" surface: thumbnail strip (reorder/delete), manual crop, stitch
/// action with progress, full-screen preview, and error alert. Driven entirely by `StitchViewModel`.
///
/// Reused by BOTH entry points (SPEC_v2 §0): v1's PhotosPicker flow (`ContentView`) and v2's
/// post-capture review (`CaptureReviewView`). The only difference between the two is how `images`
/// gets populated; everything downstream is identical, so it lives here once.
struct StitchReviewView: View {
    @ObservedObject var model: StitchViewModel

    var body: some View {
        VStack(spacing: 16) {
            ThumbnailStrip(images: $model.images)
            cropControls
            Spacer(minLength: 0)
            controls
        }
        .padding(.vertical)
        .fullScreenCover(item: $model.result) { result in
            PreviewView(image: result.image)
        }
        .alert("拼接失败", isPresented: $model.isShowingError, presenting: model.errorMessage) { _ in
            Button("好", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    // MARK: - Sections

    private var cropControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("手动裁剪(去除状态栏 / 导航栏)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            cropSlider("顶部", value: $model.topCropFraction)
            cropSlider("底部", value: $model.bottomCropFraction)
        }
        .padding(.horizontal)
    }

    private func cropSlider(_ label: String, value: Binding<Float>) -> some View {
        HStack {
            Text(label).font(.caption)
            Slider(value: value, in: 0...0.3)
            Text("\(Int(value.wrappedValue * 100))%")
                .font(.caption.monospacedDigit())
                .frame(width: 36, alignment: .trailing)
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            if model.isStitching {
                ProgressView(value: model.progress) {
                    Text("正在拼接… \(Int(model.progress * 100))%")
                        .font(.subheadline)
                }
                .padding(.horizontal)
            }

            Button {
                model.stitch()
            } label: {
                Label("拼接", systemImage: "arrow.down.to.line.compact")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal)
            .disabled(model.images.count < 2 || model.isStitching)
        }
    }
}
