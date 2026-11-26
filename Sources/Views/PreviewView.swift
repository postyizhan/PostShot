// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import UIKit

/// Displays the stitched long image with pinch-zoom and scroll, plus save/share actions.
struct PreviewView: View {
    let image: CGImage

    @Environment(\.dismiss) private var dismiss
    @State private var shareURL: URL?
    @State private var isShowingShare = false
    @State private var statusMessage: String?
    @State private var isSaving = false
    @State private var isExporting = false
    @State private var flashTask: Task<Void, Never>?

    /// Caps the on-screen preview below Metal's 16,384 px 2D texture limit while `save()` and
    /// `share()` continue exporting the full-resolution `CGImage`.
    private var displayImage: UIImage {
        let maxEdge = max(image.width, image.height)
        let maxTextureEdge = 12_000
        guard maxEdge > maxTextureEdge else { return UIImage(cgImage: image) }
        let ratio = CGFloat(maxTextureEdge) / CGFloat(maxEdge)
        let w = max(1, Int((CGFloat(image.width) * ratio).rounded()))
        let h = max(1, Int((CGFloat(image.height) * ratio).rounded()))
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return UIImage(cgImage: image) }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return UIImage(cgImage: image) }
        return UIImage(cgImage: scaled)
    }

    var body: some View {
        NavigationStack {
            ZoomableScrollView {
                Image(uiImage: displayImage)
                    .resizable()
                    .scaledToFit()
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom) { actionBar }
            .navigationTitle("拼接结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
            .sheet(isPresented: $isShowingShare, onDismiss: cleanupShareFile) {
                if let shareURL {
                    ShareSheet(items: [shareURL])
                }
            }
            .overlay(alignment: .top) { statusBanner }
            .onDisappear { cleanupShareFile() }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 16) {
            Button {
                Task { await save() }
            } label: {
                Label("保存到相册", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSaving || isExporting)

            Button {
                Task { await share() }
            } label: {
                Label("分享", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isSaving || isExporting)
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    @ViewBuilder private var statusBanner: some View {
        if let statusMessage {
            Text(statusMessage)
                .font(.subheadline)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Actions

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await PhotoSaver.save(image)
            flash("已保存到相册")
        } catch PhotoSaver.PhotoSaverError.authorizationDenied {
            flash("没有相册权限,请在设置中开启")
        } catch {
            flash("保存失败:\(error.localizedDescription)")
        }
    }

    private func share() async {
        isExporting = true
        defer { isExporting = false }
        cleanupShareFile()
        let cgImage = image
        do {
            let url = try await Task.detached(priority: .userInitiated) {
                let data = try ImageExporter.export(cgImage, as: .png)
                return try ImageExporter.writeTemporaryFile(data, fileExtension: "png")
            }.value
            shareURL = url
            isShowingShare = true
        } catch {
            flash("导出失败：\(error.localizedDescription)")
        }
    }

    private func cleanupShareFile() {
        guard let url = shareURL else { return }
        try? FileManager.default.removeItem(at: url)
        shareURL = nil
    }

    private func flash(_ message: String) {
        flashTask?.cancel()
        withAnimation { statusMessage = message }
        flashTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { statusMessage = nil }
        }
    }
}
