// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import UIKit

/// Half/large sheet for configuring export format, quality, DPI, target album,
/// saving to Photos, sharing, and optionally cleaning up source screenshots.
struct ExportSheetView: View {
    let image: CGImage
    var sourceAssetIdentifiers: [String] = []
    var hasUnsavedMarkup: Bool = false

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var selectedFormat: ExportFormat = .png
    @State private var quality: Double = 0.85
    @State private var didInitialize = false
    @State private var previewThumb: UIImage?
    @State private var estimatedByteCount: Int?
    @State private var isEstimatingSize = false
    @State private var estimateTask: Task<Void, Never>?

    @State private var isSaving = false
    @State private var isSaved = false
    @State private var isExporting = false
    @State private var isDeletingOriginals = false
    @State private var showDeleteBar = false
    @State private var showAlbumPicker = false
    @State private var shareURL: URL?
    @State private var isShowingShare = false
    @State private var toastMessage: String?
    @State private var toastIsError = false
    @State private var toastTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    headerCard
                    optionsCard
                    if showDeleteBar && !sourceAssetIdentifiers.isEmpty {
                        deleteOriginalsBar
                    }
                    actionButtons
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("导出长图")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .tint(DesignTokens.ink)
        .overlay(alignment: .top) { toastOverlay }
        .sheet(isPresented: $showAlbumPicker) {
            AlbumPickerSheet(selectedAlbumName: $settings.targetAlbumName)
        }
        .sheet(isPresented: $isShowingShare, onDismiss: handleShareDismiss) {
            if let shareURL { ShareSheet(items: [shareURL]) }
        }
        .onAppear { loadInitialSettings(); scheduleSizeEstimate() }
        .onDisappear { estimateTask?.cancel(); cleanupShareFile() }
        .onChange(of: selectedFormat) { _ in isSaved = false; scheduleSizeEstimate() }
        .onChange(of: quality) { _ in isSaved = false; scheduleSizeEstimate() }
        .task { previewThumb = await makePreviewThumb(for: image) }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Sections

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                thumbnailView
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(image.width) × \(image.height) px")
                        .font(.headline).monospacedDigit()
                    HStack(spacing: 8) {
                        Text(selectedFormat.shortName).capsuleLabelStyle()
                        if selectedFormat.supportsQuality {
                            Text("\(Int((quality * 100).rounded()))%")
                                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        }
                        if isEstimatingSize && estimatedByteCount == nil {
                            ProgressView().controlSize(.mini)
                        } else if let bytes = estimatedByteCount {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.primary)
                                .opacity(isEstimatingSize ? 0.55 : 1)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            if hasUnsavedMarkup {
                Label("标注与美化合成将于后续版本支持，本次导出原拼接图", systemImage: "exclamationmark.triangle")
                    .font(.caption.weight(.medium)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14).appleCard()
    }

    private var thumbnailView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.tertiarySystemGroupedBackground))
            if let previewThumb {
                Image(uiImage: previewThumb).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous)).padding(4)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: 56, height: 72)
    }

    private var optionsCard: some View {
        VStack(spacing: 0) {
            formatRow
            if selectedFormat.supportsQuality {
                Divider().padding(.leading, 14)
                qualityRow
            }
            Divider().padding(.leading, 14)
            dpiRow
            Divider().padding(.leading, 14)
            albumRow
        }
        .appleCard()
    }

    private var formatRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("图片格式").font(.subheadline.weight(.medium))
            Picker("图片格式", selection: $selectedFormat) {
                ForEach(ExportFormat.allCases) { Text($0.shortName).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .padding(14)
    }

    private var qualityRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("清晰度").font(.subheadline.weight(.medium))
                Spacer()
                Text(selectedFormat.supportsQuality ? "\(Int((quality * 100).rounded()))%" : "无损 100%")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: $quality, in: 0.1...1.0, step: 0.05)
                .tint(DesignTokens.ink)
                .disabled(!selectedFormat.supportsQuality)
                .opacity(selectedFormat.supportsQuality ? 1 : 0.45)
        }
        .padding(14)
    }

    private var dpiRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("分辨率 (DPI)").font(.subheadline.weight(.medium))
                Text("元数据写入即将接入").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("分辨率", selection: $settings.exportDPI) {
                ForEach(ExportDPI.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.menu)
            .tint(.secondary)
        }
        .padding(14)
    }

    private var albumRow: some View {
        Button { showAlbumPicker = true } label: {
            HStack {
                Text("目标相册").font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                Spacer()
                Text(settings.targetAlbumDisplayName).font(.subheadline).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(14).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            saveButton
            Button { Task { await shareImage() } } label: {
                HStack(spacing: 8) {
                    if isExporting { ProgressView().controlSize(.small) } else { Image(systemName: "square.and.arrow.up") }
                    Text(isExporting ? "正在准备分享…" : "分享长图")
                }
            }
            .buttonStyle(AppleSecondaryButtonStyle())
            .disabled(isSaving || isExporting)
        }
    }

    @ViewBuilder
    private var saveButton: some View {
        if isSaved {
            Button { Task { await saveToPhotos() } } label: {
                Label("已保存", systemImage: "checkmark")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 15).padding(.horizontal, 20)
                    .background(DesignTokens.success, in: Capsule())
            }
            .buttonStyle(.plain).transition(.opacity)
        } else {
            Button { Task { await saveToPhotos() } } label: {
                HStack(spacing: 8) {
                    if isSaving { ProgressView().tint(DesignTokens.onInk).controlSize(.small) } else { Image(systemName: "square.and.arrow.down") }
                    Text(isSaving ? "正在保存…" : "保存到相册")
                }
            }
            .buttonStyle(ApplePrimaryButtonStyle())
            .disabled(isSaving || isExporting)
            .transition(.opacity)
        }
    }

    private var deleteOriginalsBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "trash").font(.subheadline).foregroundStyle(.orange)
            Text("清理 \(sourceAssetIdentifiers.count) 张原截图（移入最近删除）")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button { Task { await deleteOriginals() } } label: {
                if isDeletingOriginals { ProgressView().controlSize(.mini) } else { Text("清理").font(.caption.weight(.semibold)) }
            }
            .buttonStyle(.borderedProminent).tint(.orange).controlSize(.small)
            .disabled(isDeletingOriginals)
        }
        .padding(12).appleCard(cornerRadius: 14)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let toastMessage {
            AppleToastBanner(
                message: toastMessage,
                systemImage: toastIsError ? "exclamationmark.circle.fill" : "checkmark.circle.fill",
                tint: toastIsError ? .orange : DesignTokens.success
            )
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Actions

    private func loadInitialSettings() {
        guard !didInitialize else { return }
        selectedFormat = settings.defaultExportFormat
        quality = settings.exportQuality
        didInitialize = true
    }

    private func saveToPhotos() async {
        isSaving = true
        defer { isSaving = false }
        let feedback = FeedbackManager(
            soundEnabled: settings.soundEnabled,
            hapticsEnabled: settings.hapticsEnabled
        )
        let format = selectedFormat.imageFormat(quality: quality)
        do {
            try await PhotoSaver.save(image, format: format)
            feedback.success()
            withAnimation(AppleMotion.snappy) { isSaved = true }
            showToast("已保存到相册")
            maybeShowDeleteBar()
        } catch PhotoSaver.PhotoSaverError.authorizationDenied {
            feedback.error()
            showToast("没有相册权限，请在设置中开启", isError: true)
        } catch {
            feedback.error()
            showToast("保存失败：\(error.localizedDescription)", isError: true)
        }
    }

    private func shareImage() async {
        isExporting = true
        defer { isExporting = false }
        cleanupShareFile()
        let cgImage = image
        let fmt = selectedFormat.imageFormat(quality: quality)
        let ext = selectedFormat.fileExtension
        do {
            let url = try await Task.detached(priority: .userInitiated) {
                let data = try ImageExporter.export(cgImage, as: fmt)
                return try ImageExporter.writeTemporaryFile(data, fileExtension: ext)
            }.value
            shareURL = url
            isShowingShare = true
            if settings.saveStitchedOnShare {
                Task { try? await PhotoSaver.save(cgImage, format: fmt) }
            }
        } catch {
            showToast("导出失败：\(error.localizedDescription)", isError: true)
        }
    }

    private func handleShareDismiss() {
        cleanupShareFile()
        maybeShowDeleteBar()
    }

    private func maybeShowDeleteBar() {
        guard settings.deleteOriginalsAfterExport,
              !sourceAssetIdentifiers.isEmpty else { return }
        withAnimation(AppleMotion.snappy) { showDeleteBar = true }
    }

    private func deleteOriginals() async {
        isDeletingOriginals = true
        defer { isDeletingOriginals = false }
        do {
            let count = try await PhotoSaver.deleteOriginalAssets(identifiers: sourceAssetIdentifiers)
            withAnimation(AppleMotion.snappy) { showDeleteBar = false }
            showToast("已移入最近删除（\(count) 张）")
        } catch PhotoSaver.PhotoSaverError.deleteCancelled {
            showToast("已取消清理", isError: true)
        } catch PhotoSaver.PhotoSaverError.authorizationDenied {
            showToast("需要相册读写权限", isError: true)
        } catch {
            showToast("清理失败：\(error.localizedDescription)", isError: true)
        }
    }

    private func scheduleSizeEstimate() {
        estimateTask?.cancel(); isEstimatingSize = true
        let cgImage = image, fmt = selectedFormat.imageFormat(quality: quality)
        estimateTask = Task {
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard !Task.isCancelled else { return }
            let bytes = await Task.detached(priority: .utility) { try? ImageExporter.export(cgImage, as: fmt).count }.value
            guard !Task.isCancelled else { return }
            estimatedByteCount = bytes; isEstimatingSize = false
        }
    }

    private func cleanupShareFile() {
        guard let url = shareURL else { return }
        try? FileManager.default.removeItem(at: url)
        shareURL = nil
    }

    private func showToast(_ message: String, isError: Bool = false) {
        toastTask?.cancel()
        toastIsError = isError
        withAnimation(AppleMotion.snappy) { toastMessage = message }
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(AppleMotion.gentle) { toastMessage = nil }
        }
    }

    private func makePreviewThumb(for cgImage: CGImage) async -> UIImage {
        await Task.detached(priority: .utility) {
            let maxEdge = max(cgImage.width, cgImage.height)
            let targetMax = 240
            guard maxEdge > targetMax else { return UIImage(cgImage: cgImage) }
            let ratio = CGFloat(targetMax) / CGFloat(maxEdge)
            let w = max(1, Int((CGFloat(cgImage.width) * ratio).rounded()))
            let h = max(1, Int((CGFloat(cgImage.height) * ratio).rounded()))
            let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return UIImage(cgImage: cgImage) }
            ctx.interpolationQuality = .medium
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return ctx.makeImage().map(UIImage.init(cgImage:)) ?? UIImage(cgImage: cgImage)
        }.value
    }
}
