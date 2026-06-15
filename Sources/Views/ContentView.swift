// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import PhotosUI

/// Main screen: pick screenshots, reorder/trim, stitch, then preview the result.
struct ContentView: View {
    @StateObject private var model = StitchViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if model.images.isEmpty {
                    emptyState
                } else {
                    ThumbnailStrip(images: $model.images)
                    cropControls
                }

                Spacer(minLength: 0)

                controls
            }
            .padding(.vertical)
            .navigationTitle("驿站截图")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !model.images.isEmpty {
                        Button("清空") { model.clear() }
                    }
                }
            }
            .fullScreenCover(item: $model.result) { result in
                PreviewView(image: result.image)
            }
            .alert("拼接失败", isPresented: $model.isShowingError, presenting: model.errorMessage) { _ in
                Button("好", role: .cancel) {}
            } message: { message in
                Text(message)
            }
        }
    }

    // MARK: - Sections

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("选择多张截图,自动拼接成一张长图")
                .font(.headline)
            Text("先用系统截图截好若干张,再到这里选中拼接")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxHeight: .infinity)
    }

    private var cropControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("手动裁剪(去除状态栏 / 导航栏)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                Text("顶部")
                    .font(.caption)
                Slider(value: $model.topCropFraction, in: 0...0.3)
                Text("\(Int(model.topCropFraction * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 36, alignment: .trailing)
            }
            HStack {
                Text("底部")
                    .font(.caption)
                Slider(value: $model.bottomCropFraction, in: 0...0.3)
                Text("\(Int(model.bottomCropFraction * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 36, alignment: .trailing)
            }
        }
        .padding(.horizontal)
    }

    private var controls: some View {
        let hasImages = !model.images.isEmpty
        return VStack(spacing: 12) {
            if model.isStitching {
                ProgressView(value: model.progress) {
                    Text("正在拼接… \(Int(model.progress * 100))%")
                        .font(.subheadline)
                }
                .padding(.horizontal)
            }

            PhotosPicker(
                selection: $model.pickerItems,
                maxSelectionCount: 20,
                matching: .images
            ) {
                Label(hasImages ? "重新选择" : "选择截图",
                      systemImage: "photo.on.rectangle.angled")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal)
            .disabled(model.isStitching)

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
