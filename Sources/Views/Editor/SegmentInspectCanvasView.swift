// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import PhotosUI
import UIKit

/// Interactive stitched-canvas view for inspecting, previewing, replacing, or deleting individual segments.
struct SegmentInspectCanvasView: View {
    @ObservedObject var model: StitchViewModel
    let displayResultImage: UIImage?
    let onPreviewSingle: (Int) -> Void

    @State private var selectedSpanID: Int?
    @State private var replacePickerItem: PhotosPickerItem?
    @State private var isReplacing = false

    private var selectedSpan: SegmentSpan? {
        guard let selectedSpanID, let spans = model.result?.segmentSpans else { return nil }
        return spans.first { $0.id == selectedSpanID }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            stageBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            actionBar
                .padding(.horizontal, 20)
                .padding(.bottom, 80)
        }
        .onChange(of: model.result?.id) { _ in selectedSpanID = nil }
        .onChange(of: replacePickerItem) { item in
            guard let item, let srcIdx = selectedSpan?.sourceIndex else {
                replacePickerItem = nil
                return
            }
            Task { await handleReplace(at: srcIdx, with: item) }
        }
    }

    @ViewBuilder
    private var stageBody: some View {
        if model.isStitching || isReplacing {
            VStack(spacing: 12) {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .tint(DesignTokens.ink)
                    .frame(width: 180)
                Text(isReplacing ? "正在替换图片…" : "正在重新拼接…")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .porcelainCardStyle(cornerRadius: 20)
        } else if let image = displayResultImage, let spans = model.result?.segmentSpans, !spans.isEmpty {
            ZoomableScrollView(isDoubleTapZoomEnabled: false) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .overlay { segmentBandsOverlay(spans: spans) }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .porcelainCardStyle(cornerRadius: 16)
                    .padding(.horizontal, 20)
                    .padding(.top, 112)
                    .padding(.bottom, 144)
            }
            .ignoresSafeArea()
        } else {
            AppleEmptyStateView(
                systemImage: "square.stack",
                title: "暂无可查看的分段",
                subtitle: "完成拼接后可在此轻点长图分段进行预览、替换或删除。"
            )
        }
    }

    private func segmentBandsOverlay(spans: [SegmentSpan]) -> some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let h = max(1, geo.size.height)
            ZStack(alignment: .topLeading) {
                ForEach(spans) { span in
                    let top = span.topFraction * h
                    let bandH = max(1, (span.bottomFraction - span.topFraction) * h)
                    segmentBand(span: span, width: w, height: bandH)
                        .offset(y: top)
                }
            }
        }
    }

    private func segmentBand(span: SegmentSpan, width: CGFloat, height: CGFloat) -> some View {
        let isSelected = selectedSpanID == span.id
        let badgeText = span.sourceIndex.map { "#\($0 + 1)" } ?? "补齐"
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(isSelected ? DesignTokens.ink.opacity(0.12) : Color.clear)
            if span.id > 0 {
                seamHairline(width: width, highlighted: isSelected)
            }
            if isSelected {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(DesignTokens.ink, lineWidth: 2)
                Text(badgeText)
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(DesignTokens.onInk)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(DesignTokens.ink, in: Capsule())
                    .padding(8)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(AppleMotion.snappy) {
                selectedSpanID = isSelected ? nil : span.id
            }
        }
    }

    private func seamHairline(width: CGFloat, highlighted: Bool) -> some View {
        Path { path in
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: width, y: 0))
        }
        .stroke(
            highlighted ? DesignTokens.ink : Color.primary.opacity(0.24),
            style: StrokeStyle(lineWidth: 1, dash: [5, 4])
        )
        .frame(height: 1)
    }

    @ViewBuilder
    private var actionBar: some View {
        if let span = selectedSpan {
            if let srcIdx = span.sourceIndex, model.images.indices.contains(srcIdx) {
                selectedSegmentPill(sourceIndex: srcIdx)
            } else {
                hintPill("录屏自动补齐帧（不可单独编辑）")
            }
        } else if model.result?.segmentSpans.isEmpty == false {
            hintPill("轻点长图分段可预览、替换或删除")
        }
    }

    private func selectedSegmentPill(sourceIndex: Int) -> some View {
        let canDelete = model.images.count > 2 && !model.isStitching && !isReplacing
        return ViewThatFits(in: .horizontal) {
            selectedSegmentRow(sourceIndex: sourceIndex, canDelete: canDelete)
            ScrollView(.horizontal, showsIndicators: false) {
                selectedSegmentRow(sourceIndex: sourceIndex, canDelete: canDelete)
            }
        }
        .clipShape(Capsule())
        .liquidGlass(in: Capsule(), interactive: true)
    }

    private func selectedSegmentRow(sourceIndex: Int, canDelete: Bool) -> some View {
        HStack(spacing: 6) {
            Text("第 \(sourceIndex + 1) 张")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(DesignTokens.onInk)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(DesignTokens.ink, in: Capsule())

            Button { onPreviewSingle(sourceIndex) } label: {
                segmentActionLabel("预览", systemImage: "magnifyingglass")
            }
            .buttonStyle(.plain)

            PhotosPicker(selection: $replacePickerItem, matching: .images, photoLibrary: .shared()) {
                segmentActionLabel("替换", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(model.isStitching || isReplacing)

            Button {
                selectedSpanID = nil
                model.removeFrameInEditor(at: sourceIndex)
            } label: {
                segmentActionLabel("删除", systemImage: "trash", tint: canDelete ? Color.red : Color.secondary.opacity(0.45))
            }
            .buttonStyle(.plain)
            .disabled(!canDelete)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    nonisolated private func segmentActionLabel(_ title: String, systemImage: String, tint: Color = .primary) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
    }

    private func hintPill(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .liquidGlass(in: Capsule())
            .allowsHitTesting(false)
    }

    private func handleReplace(at index: Int, with item: PhotosPickerItem) async {
        isReplacing = true
        replacePickerItem = nil
        _ = await model.replaceFrame(at: index, with: item)
        selectedSpanID = nil
        isReplacing = false
    }
}
