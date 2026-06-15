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

    private var uiImage: UIImage { UIImage(cgImage: image) }

    var body: some View {
        NavigationStack {
            ZoomableScrollView {
                Image(uiImage: uiImage)
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
            .sheet(isPresented: $isShowingShare) {
                if let shareURL {
                    ShareSheet(items: [shareURL])
                }
            }
            .overlay(alignment: .top) { statusBanner }
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
            .disabled(isSaving)

            Button {
                share()
            } label: {
                Label("分享", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
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

    private func share() {
        do {
            let data = try ImageExporter.export(image, as: .png)
            shareURL = try ImageExporter.writeTemporaryFile(data, fileExtension: "png")
            isShowingShare = true
        } catch {
            flash("导出失败:\(error.localizedDescription)")
        }
    }

    private func flash(_ message: String) {
        withAnimation { statusMessage = message }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { statusMessage = nil }
        }
    }
}
