// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import UIKit

/// iOS 26 Photos-style 2-layer editor: clean Preview state with neutral Liquid Glass controls,
/// and Unified Edit Mode (`取消` / dirty-yellow `完成`, `裁剪 | 标注 | 美化`).
struct StitchEditorView: View {
    private enum EditorMode: Equatable { case preview, edit }

    @ObservedObject var model: StitchViewModel
    var allowReselectPicker: Bool = false
    var onClose: (() -> Void)? = nil

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var mode: EditorMode = .preview
    @State private var editTab: EditorPrimaryTab = .crop
    @State private var isChromeHidden = false
    @State private var cropTab: CropAdjustTab = .top
    @State private var activeMarkupTool: EditorTool? = .draw
    @State private var markup = EditorMarkupState()
    @State private var selectedIndex: Int = 0
    @State private var displayResultImage: UIImage?
    @State private var previewSingleIndex: Int?
    @State private var pendingPreviewIndex: Int?
    @State private var showExportSheet = false
    @State private var showFramesSheet = false
    @State private var showTextPrompt = false
    @State private var pendingStickerText = ""
    @State private var viewportTracker = ZoomViewportTracker()
    @State private var markupCancelToken = 0
    @State private var displayTask: Task<Void, Never>?
    @State private var didRunInitialStitch = false
    @State private var editSnapshot: EditSessionSnapshot?
    @State private var lastStitchedCropParams: CropParams?
    @State private var framesSnapshot: [UUID]?

    private var isDrawingToolActive: Bool {
        mode == .edit && editTab == .markup
            && (activeMarkupTool == .draw || (activeMarkupTool == .redact && markup.redactMode == .manual))
    }

    var body: some View {
        ZStack { Color(.systemBackground).ignoresSafeArea(); centerStage }
            .overlay(alignment: .top) { topFloatingBar }
            .overlay(alignment: .bottom) { bottomFloatingBar }
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            .task { await runInitialSetup() }
            .onChange(of: mode) { if $0 != .preview { isChromeHidden = false } }
            .onChange(of: editTab) { if $0 != .crop { stitchIfCropParamsDirty() } }
            .onChange(of: cropTab) { if $0 == .segments { stitchIfCropParamsDirty() } }
            .onChange(of: model.result?.id) { handleResultChange($0) }
            .onChange(of: model.images.map(\.id)) { _ in handleImagesChanged() }
            .onDisappear { displayTask?.cancel() }
            .sheet(isPresented: $showFramesSheet, onDismiss: handleFramesSheetDismiss) {
                SourceFramesSheet(model: model, selectedIndex: $selectedIndex, allowReselectPicker: allowReselectPicker) { pendingPreviewIndex = $0; showFramesSheet = false }
            }
            .sheet(item: previewItemBinding) { SingleImagePreviewView(initialIndex: $0.index, images: model.images, onDelete: handleDeleteImage(at:)) }
            .sheet(isPresented: $showExportSheet) {
                if let r = model.result {
                    ExportSheetView(image: r.image, sourceAssetIdentifiers: r.sourceAssetIdentifiers, hasUnsavedMarkup: markup.hasActiveAnnotations).environmentObject(settings)
                }
            }
            .alert("拼接失败", isPresented: $model.isShowingError, presenting: model.errorMessage) { _ in Button("好", role: .cancel) {} } message: { Text($0) }
            .alert("添加文字贴纸", isPresented: $showTextPrompt) {
                TextField("输入贴纸文字", text: $pendingStickerText)
                Button("取消", role: .cancel) { pendingStickerText = "" }
                Button("添加") { commitSticker() }
            } message: { Text("添加后可在画布上拖动位置") }
    }

    // MARK: - Top Floating Bar

    private var topFloatingBar: some View {
        let chromeHidden = mode == .preview && isChromeHidden
        return Group {
            if mode == .preview {
                ZStack {
                    previewTitleCapsule
                    HStack(spacing: 10) {
                        AdaptiveGlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "返回") {
                            if let onClose { onClose() } else { dismiss() }
                        }
                        Spacer(minLength: 8)
                        previewMoreMenu
                    }
                }
            } else {
                VStack(spacing: 8) {
                    EditTopBar(
                        hasEdits: hasEditsInSession,
                        statusCaption: editStatusCaption,
                        onCancel: { exitEditMode(applyChanges: false) },
                        onDone: { exitEditMode(applyChanges: true) }
                    )
                    EditSubSelectorBar(
                        editTab: editTab,
                        cropTab: $cropTab,
                        activeMarkupTool: $activeMarkupTool,
                        hasAnnotations: markup.hasActiveAnnotations,
                        onUndo: { markup.undoLast() }
                    )
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 6)
        .opacity(chromeHidden ? 0 : 1).allowsHitTesting(!chromeHidden)
    }

    private var previewTitleCapsule: some View {
        let subtitle = model.result.map { "\($0.image.width) × \($0.image.height) · \(settings.defaultExportFormat.shortName)" }
            ?? "\(model.images.count) 张截图"
        return VStack(spacing: 1) {
            Text("拼接结果").font(.footnote.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
            Text(subtitle).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 18).padding(.vertical, 7).liquidGlass(in: Capsule())
    }

    private var previewMoreMenu: some View {
        Menu {
            Button { Task { await model.suggestFixedBarCropAsync(); model.stitch() } } label: {
                Label("恢复自动裁剪", systemImage: "crop.rotate")
            }.disabled(model.images.count < 2 || model.isStitching)
            Button { framesSnapshot = model.images.map(\.id); showFramesSheet = true } label: {
                Label("管理原图", systemImage: "photo.stack")
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 17, weight: .medium)).foregroundStyle(.primary)
                .frame(width: 44, height: 44).liquidGlass(in: Circle(), interactive: true).contentShape(Circle())
        }
        .accessibilityLabel("更多选项")
    }

    private var editStatusCaption: String? {
        guard editTab == .markup else { return nil }
        return isDrawingToolActive ? "单指标注 · 双指滚动" : "单指滚动浏览"
    }

    // MARK: - Center Stage

    @ViewBuilder
    private var centerStage: some View {
        Group {
            if mode == .edit && editTab == .crop {
                VisualCropCanvasView(model: model, cropTab: $cropTab, displayResultImage: displayResultImage) { previewSingleIndex = $0 }
            } else if let seam = model.failedSeam {
                SeamFailureRecoveryView(seam: seam, model: model) { framesSnapshot = model.images.map(\.id); showFramesSheet = true }
            } else if model.isStitching || (model.result != nil && displayResultImage == nil) {
                VStack(spacing: 14) {
                    ProgressView(value: model.progress).progressViewStyle(.linear).tint(DesignTokens.accentBlue).frame(width: 200)
                    Text("正在拼接… \(Int((model.progress * 100).rounded()))%").font(.subheadline.weight(.medium)).monospacedDigit()
                }
                .padding(.horizontal, 24).padding(.vertical, 22).porcelainCardStyle(cornerRadius: 20)
            } else if let displayResultImage {
                resultPreviewStage(image: displayResultImage)
            } else {
                AppleEmptyStateView(systemImage: "photo.on.rectangle.angled", title: "需要至少 2 张截图", subtitle: "返回重新选择至少 2 张截图即可自动拼接。")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultPreviewStage(image: UIImage) -> some View {
        let topPad: CGFloat = isChromeHidden ? 16 : (mode == .edit ? 112 : 64)
        let bottomPad: CGFloat = isChromeHidden ? 24 : (mode == .edit ? 148 : 84)
        return ZoomableScrollView(
            isDrawingActive: isDrawingToolActive, isDoubleTapZoomEnabled: !isDrawingToolActive,
            viewportTracker: viewportTracker,
            onScrollOrZoomBegan: { markupCancelToken &+= 1 },
            onSingleTap: mode == .preview ? { withAnimation(AppleMotion.gentle) { isChromeHidden.toggle() } } : nil
        ) {
            beautifiedResultImage(image)
                .padding(.horizontal, max(16, markup.beautifyPadding))
                .padding(.top, topPad).padding(.bottom, bottomPad)
        }
        .overlay(alignment: .top) {
            if mode == .preview, let notice = model.stitchNotice, !isChromeHidden {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(DesignTokens.accentBlue)
                    Text(notice).font(.caption.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                }
                .padding(.horizontal, 12).padding(.vertical, 6).liquidGlass(in: Capsule()).padding(.top, 64).allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func beautifiedResultImage(_ image: UIImage) -> some View {
        let shape = RoundedRectangle(cornerRadius: markup.beautifyCornerRadius, style: .continuous)
        let isMarkupInteractive = (mode == .edit && editTab == .markup)
        let annotated = Image(uiImage: image).resizable().scaledToFit().overlay {
            EditorMarkupOverlay(activeTool: isMarkupInteractive ? activeMarkupTool : nil,
                                isInteractive: isMarkupInteractive, cancelToken: markupCancelToken, markup: $markup)
        }
        Group {
            if markup.beautifyShadow { annotated.porcelainCardStyle(cornerRadius: markup.beautifyCornerRadius) }
            else { annotated.clipShape(shape).overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)) }
        }
        .overlay { if markup.beautifyFrame { shape.strokeBorder(Color.primary.opacity(0.18), lineWidth: 2) } }
    }

    // MARK: - Bottom Floating Bar

    private var bottomFloatingBar: some View {
        let chromeHidden = mode == .preview && isChromeHidden
        return VStack(spacing: 10) {
            if mode == .preview {
                PreviewBottomBar(
                    canExport: model.result != nil && !model.isStitching,
                    canEdit: model.images.count >= 2 && !model.isStitching,
                    onShare: { showExportSheet = true },
                    onEnterEdit: enterEditMode
                )
            } else {
                if editTab == .markup, activeMarkupTool != nil {
                    EditorMarkupDock(activeTool: $activeMarkupTool, markup: $markup) { pendingStickerText = ""; showTextPrompt = true }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if editTab == .beautify {
                    EditorBeautifyDock(markup: $markup).transition(.move(edge: .bottom).combined(with: .opacity))
                }
                EditorPrimaryTabPill(selectedTab: $editTab, modifiedTabs: modifiedEditTabs)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 8).opacity(chromeHidden ? 0 : 1).allowsHitTesting(!chromeHidden)
    }
}

// MARK: - State & Actions

private extension StitchEditorView {
    var previewItemBinding: Binding<PreviewIndexBox?> {
        Binding(get: { previewSingleIndex.map(PreviewIndexBox.init(index:)) }, set: { previewSingleIndex = $0?.index })
    }
    var currentCropParams: CropParams {
        CropParams(topCropFraction: model.topCropFraction, bottomCropFraction: model.bottomCropFraction,
                   headerMode: model.headerMode, keepFooter: model.keepFooter)
    }
    var hasCropEditsInSession: Bool {
        guard let snap = editSnapshot else { return false }
        return currentCropParams != snap.cropParams || model.images.map(\.id) != snap.imageIDs
    }
    var hasEditsInSession: Bool {
        guard let snap = editSnapshot else { return false }
        return hasCropEditsInSession || markup.hasMarkupChanges(comparedTo: snap.markup) || markup.hasBeautifyChanges(comparedTo: snap.markup)
    }
    var modifiedEditTabs: Set<EditorPrimaryTab> {
        guard let snap = editSnapshot else { return [] }
        var tabs: Set<EditorPrimaryTab> = []
        if hasCropEditsInSession { tabs.insert(.crop) }
        if markup.hasMarkupChanges(comparedTo: snap.markup) { tabs.insert(.markup) }
        if markup.hasBeautifyChanges(comparedTo: snap.markup) { tabs.insert(.beautify) }
        return tabs
    }

    func runInitialSetup() async {
        model.removeScrollIndicator = settings.removeScrollIndicatorByDefault
        guard !didRunInitialStitch else { return }
        didRunInitialStitch = true
        if let existing = model.result, displayResultImage == nil { handleResultChange(existing.id) }
        else if model.images.count >= 2 && model.result == nil && model.failedSeam == nil && !model.isStitching {
            if model.topCropFraction == 0 && model.bottomCropFraction == 0 { await model.suggestFixedBarCropAsync() }
            model.stitch()
        }
    }

    func enterEditMode() {
        let params = currentCropParams
        editSnapshot = EditSessionSnapshot(cropParams: params, imageIDs: model.images.map(\.id), images: model.images, result: model.result, markup: markup)
        lastStitchedCropParams = params
        editTab = .crop; cropTab = .top; isChromeHidden = false
        withAnimation(AppleMotion.snappy) { mode = .edit }
    }

    func exitEditMode(applyChanges: Bool) {
        if !applyChanges, let snap = editSnapshot {
            model.topCropFraction = snap.cropParams.topCropFraction; model.bottomCropFraction = snap.cropParams.bottomCropFraction
            model.headerMode = snap.cropParams.headerMode; model.keepFooter = snap.cropParams.keepFooter
            markup = snap.markup
            if snap.imageIDs != model.images.map(\.id) || snap.result?.id != model.result?.id {
                model.images = snap.images; model.result = snap.result
            }
        }
        let hadChanges = applyChanges && hasEditsInSession
        editSnapshot = nil
        withAnimation(AppleMotion.snappy) { mode = .preview }
        guard hadChanges else { lastStitchedCropParams = nil; return }
        let needsStitch = (lastStitchedCropParams != currentCropParams) || (model.result == nil && model.failedSeam == nil)
        lastStitchedCropParams = nil
        if needsStitch, model.images.count >= 2, !model.isStitching { model.stitch() }
    }

    func stitchIfCropParamsDirty() {
        guard let last = lastStitchedCropParams, last != currentCropParams,
              model.images.count >= 2, !model.isStitching else { return }
        lastStitchedCropParams = currentCropParams
        model.stitch()
    }

    func handleFramesSheetDismiss() {
        let snap = framesSnapshot; framesSnapshot = nil
        if let snap, snap != model.images.map(\.id), model.images.count >= 2, !model.isStitching { model.stitch() }
        if let idx = pendingPreviewIndex { pendingPreviewIndex = nil; previewSingleIndex = idx }
    }

    func handleImagesChanged() {
        selectedIndex = min(selectedIndex, max(0, model.images.count - 1))
        if model.images.count < 2 { model.result = nil; return }
        if mode != .edit, !showFramesSheet, model.result == nil, !model.isStitching, model.failedSeam == nil { model.stitch() }
    }

    func handleResultChange(_ newID: UUID?) {
        displayTask?.cancel()
        guard newID != nil, let cgImage = model.result?.image else { displayResultImage = nil; return }
        displayTask = Task {
            let rendered = await Self.makeDisplayImage(for: cgImage)
            if !Task.isCancelled { displayResultImage = rendered }
        }
    }

    func handleDeleteImage(at idx: Int) {
        guard model.images.indices.contains(idx) else { return }
        model.images.remove(at: idx); selectedIndex = min(selectedIndex, max(0, model.images.count - 1))
        if model.images.isEmpty { previewSingleIndex = nil }
        if model.images.count >= 2 && !model.isStitching { model.stitch() }
    }

    func commitSticker() {
        let trimmed = pendingStickerText.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingStickerText = ""
        guard !trimmed.isEmpty else { return }
        markup.addSticker(text: trimmed, normalizedCenter: viewportTracker.normalizedCenter)
        activeMarkupTool = .text
    }

    nonisolated static func makeDisplayImage(for cgImage: CGImage) async -> UIImage {
        await Task.detached(priority: .userInitiated) {
            let maxEdge = max(cgImage.width, cgImage.height)
            guard maxEdge > 12_000 else { return UIImage(cgImage: cgImage) }
            let ratio = 12_000 / CGFloat(maxEdge), w = max(1, Int((CGFloat(cgImage.width) * ratio).rounded())), h = max(1, Int((CGFloat(cgImage.height) * ratio).rounded()))
            let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return UIImage(cgImage: cgImage) }
            ctx.interpolationQuality = .medium; ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return ctx.makeImage().map(UIImage.init(cgImage:)) ?? UIImage(cgImage: cgImage)
        }.value
    }
}

private struct CropParams: Equatable {
    let topCropFraction: Float; let bottomCropFraction: Float
    let headerMode: HeaderKeepMode; let keepFooter: Bool
}
private struct EditSessionSnapshot {
    let cropParams: CropParams; let imageIDs: [UUID]
    let images: [SelectedImage]; let result: StitchResult?; let markup: EditorMarkupState
}
private struct PreviewIndexBox: Identifiable { let index: Int; var id: Int { index } }
