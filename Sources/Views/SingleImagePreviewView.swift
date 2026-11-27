// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import UIKit

/// Dark Apple Photos-style full-screen viewer for inspecting individual screenshots
/// with paging, pinch-zoom, and optional deletion.
struct SingleImagePreviewView: View {
    let initialIndex: Int
    let images: [SelectedImage]
    var onDelete: ((Int) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int

    init(initialIndex: Int, images: [SelectedImage], onDelete: ((Int) -> Void)? = nil) {
        self.initialIndex = initialIndex
        self.images = images
        self.onDelete = onDelete
        let clamped = images.isEmpty ? 0 : min(max(0, initialIndex), images.count - 1)
        self._currentIndex = State(initialValue: clamped)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(Array(images.enumerated()), id: \.element.id) { index, img in
                    ZoomableScrollView {
                        Image(uiImage: resolvedImage(for: img))
                            .resizable()
                            .scaledToFit()
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            topGlassBar
        }
        .preferredColorScheme(.dark)
        .onChange(of: images.count) { count in
            if count == 0 {
                dismiss()
            } else if currentIndex >= count {
                currentIndex = count - 1
            }
        }
    }

    // MARK: - Overlay

    private var topGlassBar: some View {
        HStack {
            GlassCircleButton(systemImage: "xmark", accessibilityLabel: "关闭") {
                dismiss()
            }

            Spacer()

            if !images.isEmpty {
                Text(pageTitle)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        ZStack {
                            Capsule().fill(Color(white: 0.22, opacity: 0.55))
                            Capsule().fill(.ultraThinMaterial)
                        }
                    )
                    .overlay(
                        Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.28), radius: 8, y: 3)
            }

            Spacer()

            if onDelete != nil {
                GlassCircleButton(
                    systemImage: "trash",
                    accessibilityLabel: "删除此图片",
                    tint: .red,
                    action: confirmDelete
                )
            } else {
                Color.clear.frame(width: 36, height: 36)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: - Helpers

    private var pageTitle: String {
        guard !images.isEmpty else { return "" }
        let safeIndex = min(max(0, currentIndex), images.count - 1)
        return "\(safeIndex + 1) / \(images.count)"
    }

    private func resolvedImage(for item: SelectedImage) -> UIImage {
        item.cgImage.width > 1 ? UIImage(cgImage: item.cgImage) : item.thumbnail
    }

    private func confirmDelete() {
        guard images.indices.contains(currentIndex) else { return }
        let idx = currentIndex
        onDelete?(idx)
        if images.count <= 1 {
            dismiss()
        } else if currentIndex >= images.count - 1 {
            currentIndex = max(0, images.count - 2)
        }
    }
}
