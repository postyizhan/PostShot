// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import UIKit

/// Focused crop tabs for adjusting the top header, bottom footer exclusion band, or inspecting stitched segments.
enum CropAdjustTab: String, CaseIterable, Identifiable {
    case top, bottom, segments
    var id: String { rawValue }
    var title: String {
        switch self {
        case .top: return "顶部"
        case .bottom: return "底部"
        case .segments: return "分段"
        }
    }
}

/// Focused Light/Dark adaptive canvas for top header, bottom footer crop adjustments, and segment editing.
struct VisualCropCanvasView: View {
    @ObservedObject var model: StitchViewModel
    @Binding var cropTab: CropAdjustTab
    var displayResultImage: UIImage? = nil
    var onPreviewSingle: (Int) -> Void = { _ in }

    @State private var displayThumbs: [UUID: UIImage] = [:]
    @State private var isDraggingCrop = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var effectiveTopCrop: Float {
        switch model.headerMode {
        case .none: return model.topCropFraction
        case .navBarOnly: return min(model.topCropFraction, FixedBarDetector.recordingStatusBandFloor)
        case .full: return 0
        }
    }

    private var effectiveBottomCrop: Float {
        model.keepFooter ? 0 : model.bottomCropFraction
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(.systemBackground).ignoresSafeArea()
            if cropTab == .segments {
                SegmentInspectCanvasView(
                    model: model,
                    displayResultImage: displayResultImage,
                    onPreviewSingle: onPreviewSingle
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.90).combined(with: .opacity))
            } else {
                cropStageContainer
                    .transition(reduceMotion ? .opacity : .scale(scale: 1.04).combined(with: .opacity))
            }
        }
        .appleAnimation(AppleMotion.smooth, value: cropTab)
        .task(id: model.images.map(\.id)) { await buildDisplayThumbnails() }
    }

    private var cropStageContainer: some View {
        ZStack(alignment: .bottom) {
            cropContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 112).padding(.bottom, 146)
            if !model.images.isEmpty {
                contextualModePill
                    .id(cropTab).transition(.opacity)
                    .padding(.horizontal, 20).padding(.bottom, 80)
                    .appleAnimation(AppleMotion.snappy, value: cropTab)
            }
        }
    }

    @ViewBuilder
    private var cropContent: some View {
        switch cropTab {
        case .top:
            if let first = model.images.first {
                cropEdgeView(item: first, edge: .top, effectiveFraction: effectiveTopCrop, onBeginDrag: {
                    let start = effectiveTopCrop
                    if model.headerMode != .none { model.topCropFraction = start; model.headerMode = .none }
                }, onUpdateFraction: { model.topCropFraction = $0 })
                .id(CropAdjustTab.top)
                .offset(y: reduceMotion ? 0 : 6)
                .transition(cropFocusTransition(edge: .top))
            } else { emptyState }
        case .bottom:
            if let last = model.images.last {
                cropEdgeView(item: last, edge: .bottom, effectiveFraction: effectiveBottomCrop, onBeginDrag: {
                    let start = effectiveBottomCrop
                    if model.keepFooter { model.bottomCropFraction = start; model.keepFooter = false }
                }, onUpdateFraction: { model.bottomCropFraction = $0 })
                .id(CropAdjustTab.bottom)
                .offset(y: reduceMotion ? 0 : -6)
                .transition(cropFocusTransition(edge: .bottom))
            } else { emptyState }
        case .segments:
            EmptyView()
        }
    }

    private func cropFocusTransition(edge: SingleEdgeCropOverlay.Edge) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .offset(y: edge == .top ? -22 : 22).combined(with: .opacity)
    }

    private func cropEdgeView(
        item: SelectedImage, edge: SingleEdgeCropOverlay.Edge,
        effectiveFraction: Float, onBeginDrag: @escaping () -> Void, onUpdateFraction: @escaping (Float) -> Void
    ) -> some View {
        VStack(spacing: 10) {
            Text("拖动裁切线调整范围").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            cropCard(item: item, edge: edge, effectiveFraction: effectiveFraction,
                     onBeginDrag: onBeginDrag, onUpdateFraction: onUpdateFraction)
                .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var contextualModePill: some View {
        switch cropTab {
        case .top:
            CropModeGlassPill(selection: $model.headerMode,
                              segments: [(.none, "无眉头"), (.navBarOnly, "仅标题栏"), (.full, "完整顶部")],
                              isDisabled: model.isStitching)
        case .bottom:
            CropModeGlassPill(selection: $model.keepFooter,
                              segments: [(false, "隐藏底栏"), (true, "保留底栏")],
                              isDisabled: model.isStitching)
        case .segments:
            EmptyView()
        }
    }

    private func cropCard(
        item: SelectedImage, edge: SingleEdgeCropOverlay.Edge, effectiveFraction: Float,
        onBeginDrag: @escaping () -> Void, onUpdateFraction: @escaping (Float) -> Void
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        return Image(uiImage: displayThumbs[item.id] ?? UIImage(cgImage: item.cgImage))
            .resizable().aspectRatio(contentMode: .fit)
            .overlay { CropMaskLayer(edge: edge, effectiveFraction: effectiveFraction, isDragging: isDraggingCrop) }
            .clipShape(shape).porcelainCardStyle(cornerRadius: 4)
            .overlay {
                SingleEdgeCropOverlay(edge: edge, effectiveFraction: effectiveFraction, isDragging: $isDraggingCrop,
                                      onBeginDrag: onBeginDrag, onUpdateFraction: onUpdateFraction)
            }
            .padding(.horizontal, 24)
    }

    private var emptyState: some View {
        AppleEmptyStateView(systemImage: "photo.stack", title: "等待添加截图", subtitle: "添加截图后即可调整顶部与底部裁切区域。")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func buildDisplayThumbnails() async {
        let snapshot = model.images
        displayThumbs = await Task.detached(priority: .userInitiated) {
            Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, Self.downscaleForCanvas($0.cgImage, maxWidth: 900)) })
        }.value
    }

    nonisolated private static func downscaleForCanvas(_ cgImage: CGImage, maxWidth: CGFloat) -> UIImage {
        let width = CGFloat(cgImage.width), height = CGFloat(cgImage.height)
        guard width > maxWidth, width > 0, height > 0 else { return UIImage(cgImage: cgImage) }
        let target = CGSize(width: maxWidth, height: max(1, height * (maxWidth / width)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

// MARK: - Contextual Liquid Glass Mode Pill

private struct CropModeGlassPill<Value: Hashable>: View {
    @Binding var selection: Value
    let segments: [(value: Value, title: String)]
    var isDisabled: Bool = false

    @Namespace private var pillNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments, id: \.value) { segment in
                let isSelected = selection == segment.value
                Button {
                    withAnimation(AppleMotion.animation(AppleMotion.snappy, reduceMotion: reduceMotion)) {
                        selection = segment.value
                    }
                } label: {
                    Text(segment.title)
                        .font(.subheadline.weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background {
                            if isSelected {
                                Capsule().fill(Color.primary.opacity(0.10))
                                    .matchedGeometryEffect(id: "cropModeActivePill", in: pillNamespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .liquidGlass(in: Capsule(), interactive: true)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.55 : 1)
    }
}

// MARK: - Single-Edge Crop Overlay

private struct CropMaskLayer: View {
    let edge: SingleEdgeCropOverlay.Edge
    let effectiveFraction: Float
    let isDragging: Bool

    var body: some View {
        GeometryReader { geo in
            let height = max(1, geo.size.height)
            let maskHeight = height * CGFloat(effectiveFraction)
            VStack(spacing: 0) {
                if edge == .bottom { Spacer(minLength: 0) }
                Color.black.opacity(maskHeight > 0.5 ? 0.52 : 0).frame(height: maskHeight)
                if edge == .top { Spacer(minLength: 0) }
            }
            .frame(height: height)
            .animation(isDragging ? nil : AppleMotion.snappy, value: effectiveFraction)
        }
        .allowsHitTesting(false)
    }
}

private struct SingleEdgeCropOverlay: View {
    enum Edge { case top, bottom }

    let edge: Edge
    let effectiveFraction: Float
    @Binding var isDragging: Bool
    let onBeginDrag: () -> Void
    let onUpdateFraction: (Float) -> Void

    @State private var dragStartValue: Float?
    @State private var lastTickPercent: Int = -1
    private let maxCrop: Float = 0.30
    private let selectionHaptic = UISelectionFeedbackGenerator()

    var body: some View {
        GeometryReader { geo in
            let height = max(1, geo.size.height)
            let cropHeight = height * CGFloat(effectiveFraction)
            let offsetY = edge == .top ? (cropHeight - 14) : (height - cropHeight - 14)

            ZStack(alignment: .top) {
                handleBar
                    .offset(y: offsetY)
                    .animation(isDragging ? nil : AppleMotion.snappy, value: effectiveFraction)
                    .gesture(dragGesture(frameHeight: height))
                if isDragging {
                    liveCropPill.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
        }
    }

    private var handleBar: some View {
        ZStack {
            Rectangle().fill(DesignTokens.ink).frame(height: 1.5).padding(.horizontal, 2)
            Capsule().fill(DesignTokens.ink).frame(width: 44, height: 6)
                .overlay(Capsule().strokeBorder(DesignTokens.onInk.opacity(0.85), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.25), radius: 3, y: 1)
        }
        .frame(height: 28).contentShape(Rectangle())
    }

    private var liveCropPill: some View {
        let pct = Int(round(effectiveFraction * 100))
        return Text(edge == .top ? "顶部裁切 \(pct)%" : "底部裁切 \(pct)%")
            .font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.black.opacity(0.76), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.28), lineWidth: 1))
            .allowsHitTesting(false)
    }

    private func dragGesture(frameHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isDragging {
                    dragStartValue = effectiveFraction; isDragging = true
                    onBeginDrag(); selectionHaptic.prepare()
                }
                let start = dragStartValue ?? effectiveFraction
                let delta = Float(value.translation.height / frameHeight)
                let clamped = min(maxCrop, max(0, edge == .top ? (start + delta) : (start - delta)))
                onUpdateFraction(clamped)
                let pct = Int(round(clamped * 100))
                if pct != lastTickPercent { lastTickPercent = pct; selectionHaptic.selectionChanged() }
            }
            .onEnded { _ in isDragging = false; dragStartValue = nil; lastTickPercent = -1 }
    }
}

// MARK: - Seam Failure Recovery Card

/// Compact Apple warning card displaying the two failing adjacent frames with 1-tap recovery actions.
struct SeamFailureRecoveryView: View {
    let seam: StitchSeam
    @ObservedObject var model: StitchViewModel
    var onOpenFrames: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(DesignTokens.seamWarning)
                Text("第 \(seam.topIndex + 1) 张与第 \(seam.bottomIndex + 1) 张未对齐")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            }
            if let message = model.errorMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            pairPreviewRow
            recoveryButtonsRow
        }
        .padding(14).porcelainCardStyle(cornerRadius: 20)
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(DesignTokens.seamWarning.opacity(0.45), lineWidth: 1))
    }

    private var pairPreviewRow: some View {
        HStack(spacing: 12) {
            frameThumb(index: seam.topIndex)
            Image(systemName: "link.badge.plus").font(.caption.weight(.bold)).foregroundStyle(DesignTokens.seamWarning)
            frameThumb(index: seam.bottomIndex)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func frameThumb(index: Int) -> some View {
        if model.images.indices.contains(index) {
            VStack(spacing: 4) {
                Image(uiImage: model.images[index].thumbnail)
                    .resizable().aspectRatio(contentMode: .fill).frame(width: 68, height: 92)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DesignTokens.seamWarning.opacity(0.4), lineWidth: 1))
                Text("#\(index + 1)").font(.caption2.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private var recoveryButtonsRow: some View {
        let top = seam.topIndex + 1, bottom = seam.bottomIndex + 1
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if model.images.count == 2 { recoveryButton("对调重拼") { model.swapPairAndRetry() } }
                if model.images.count > 2, seam.isReverseConflict {
                    recoveryButton("倒序重拼", isPrimary: true) { model.reverseAllAndRetry() }
                }
                if model.images.count > 2 {
                    recoveryButton("删第 \(top) 张") { model.removeFrameAndRetry(at: seam.topIndex) }
                    recoveryButton("删第 \(bottom) 张") { model.removeFrameAndRetry(at: seam.bottomIndex) }
                }
                if seam.topIndex > 0, model.images.count - seam.bottomIndex >= 2 {
                    recoveryButton("从第 \(bottom) 张拼") { model.trimLeadingFramesAndRetry(from: seam.bottomIndex) }
                }
                if seam.topIndex >= 1, seam.bottomIndex < model.images.count - 1 {
                    recoveryButton("只拼前 \(top) 张") { model.trimTrailingFramesAndRetry(keepingUpTo: seam.topIndex) }
                }
                if model.images.count > 2, !seam.isReverseConflict {
                    recoveryButton("倒序重拼", isPrimary: false) { model.reverseAllAndRetry() }
                }
                recoveryButton("管理素材", isPrimary: false, action: onOpenFrames)
            }
        }
        .disabled(model.isStitching)
    }

    private func recoveryButton(_ title: String, isPrimary: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(isPrimary ? Color.white : Color.primary)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(isPrimary ? DesignTokens.seamWarning : Color.primary.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
