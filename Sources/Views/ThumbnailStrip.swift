// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// Horizontal strip of selected images. Supports delete and left/right reordering.
///
/// Drag-to-reorder in a horizontal `ScrollView` is unreliable pre-iOS 17, so v1 uses
/// explicit move buttons on each thumbnail — simple and predictable (SPEC §3).
struct ThumbnailStrip: View {
    @Binding var images: [SelectedImage]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                    ThumbnailCell(
                        image: image,
                        index: index,
                        count: images.count,
                        onDelete: { remove(at: index) },
                        onMoveLeft: { move(from: index, to: index - 1) },
                        onMoveRight: { move(from: index, to: index + 1) }
                    )
                }
            }
            .padding(.horizontal)
        }
    }

    private func remove(at index: Int) {
        guard images.indices.contains(index) else { return }
        var copy = images
        copy.remove(at: index)
        images = copy
    }

    private func move(from: Int, to: Int) {
        guard images.indices.contains(from), images.indices.contains(to) else { return }
        var copy = images
        let item = copy.remove(at: from)
        copy.insert(item, at: to)
        images = copy
    }
}

/// A single thumbnail with order index and overlaid controls.
private struct ThumbnailCell: View {
    let image: SelectedImage
    let index: Int
    let count: Int
    let onDelete: () -> Void
    let onMoveLeft: () -> Void
    let onMoveRight: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Image(uiImage: image.thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 88, height: 132)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )

                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white, .black.opacity(0.5))
                }
                .padding(4)
                .accessibilityLabel("删除第 \(index + 1) 张")
            }

            HStack(spacing: 16) {
                Button(action: onMoveLeft) {
                    Image(systemName: "chevron.left.circle")
                }
                .disabled(index == 0)
                .accessibilityLabel("左移")

                Text("\(index + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button(action: onMoveRight) {
                    Image(systemName: "chevron.right.circle")
                }
                .disabled(index == count - 1)
                .accessibilityLabel("右移")
            }
            .font(.body)
        }
    }
}
