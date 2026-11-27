// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// Shared "review and stitch" surface: thumbnail strip (reorder/delete), header/footer/scrollbar
/// options, manual crop, stitch action with progress, preview, and seam recovery card.
struct StitchReviewView: View {
    @ObservedObject var model: StitchViewModel

    var body: some View {
        VStack(spacing: 12) {
            ScrollView {
                VStack(spacing: 14) {
                    ThumbnailStrip(
                        images: $model.images,
                        highlightedSeam: model.failedSeam,
                        isDisabled: model.isStitching
                    )
                    if let notice = model.stitchNotice {
                        Label(notice, systemImage: "sparkles")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                    }
                    if let seam = model.failedSeam {
                        seamRecoveryCard(seam)
                    }
                    stitchOptionsControls
                    cropControls
                }
            }
            controls
        }
        .padding(.vertical, 8)
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

    private func seamRecoveryCard(_ seam: StitchSeam) -> some View {
        let top = seam.topIndex + 1
        let bottom = seam.bottomIndex + 1
        return VStack(alignment: .leading, spacing: 10) {
            Label(
                model.errorMessage ?? "第\(top)张与第\(bottom)张衔接中断",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if model.images.count == 2 {
                        Button("对调顺序重拼") {
                            model.swapPairAndRetry()
                        }
                    }
                    if model.images.count > 2 {
                        Button("删第 \(top) 张重拼") {
                            model.removeFrameAndRetry(at: seam.topIndex)
                        }
                        Button("删第 \(bottom) 张重拼") {
                            model.removeFrameAndRetry(at: seam.bottomIndex)
                        }
                    }
                    if seam.topIndex > 0, model.images.count - seam.bottomIndex >= 2 {
                        Button("从第 \(bottom) 张开始拼") {
                            model.trimLeadingFramesAndRetry(from: seam.bottomIndex)
                        }
                    }
                    if seam.topIndex >= 1, seam.bottomIndex < model.images.count - 1 {
                        Button("只拼前 \(top) 张") {
                            model.trimTrailingFramesAndRetry(keepingUpTo: seam.topIndex)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isStitching)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private var stitchOptionsControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("顶部眉头")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("顶部眉头", selection: $model.headerMode) {
                    Text("无眉头").tag(HeaderKeepMode.none)
                    Text("仅标题栏").tag(HeaderKeepMode.navBarOnly)
                    Text("完整顶部").tag(HeaderKeepMode.full)
                }
                .pickerStyle(.segmented)
            }
            Toggle("保留底部栏", isOn: $model.keepFooter)
                .font(.caption)
            Toggle("去除右侧滚动条", isOn: $model.removeScrollIndicator)
                .font(.caption)
        }
        .padding(.horizontal)
        .disabled(model.isStitching)
    }

    private var cropControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("手动裁剪(去除状态栏 / 导航栏)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("自动检测") {
                    Task { await model.suggestFixedBarCropAsync() }
                }
                .font(.caption)
                .disabled(model.images.count < 2 || model.isStitching)
            }
            cropSlider("顶部", value: $model.topCropFraction)
            cropSlider("底部", value: $model.bottomCropFraction)
        }
        .padding(.horizontal)
        .disabled(model.isStitching)
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
