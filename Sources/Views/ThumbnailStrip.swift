// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// Horizontal strip of selected images. Supports delete, left/right reordering, and seam
/// failure highlighting with automatic scroll-to-break.
struct ThumbnailStrip: View {
    @Binding var images: [SelectedImage]
    var highlightedSeam: StitchSeam? = nil
    var isDisabled: Bool = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                        HStack(spacing: 12) {
                            ThumbnailCell(
                                image: image,
                                index: index,
                                count: images.count,
                                isHighlighted: isSeamEndpoint(index),
                                isDisabled: isDisabled,
                                onDelete: { remove(at: index) },
                                onMoveLeft: { move(from: index, to: index - 1) },
                                onMoveRight: { move(from: index, to: index + 1) }
                            )
                            if highlightedSeam?.topIndex == index {
                                Image(systemName: "bolt.slash.fill")
                                    .font(.callout.bold())
                                    .foregroundStyle(.orange)
                                    .accessibilityLabel("第 \(index + 1) 张与第 \(index + 2) 张衔接中断")
                            }
                        }
                        .id(image.id)
                    }
                }
                .padding(.horizontal)
            }
            .onChange(of: highlightedSeam) { seam in
                guard let seam, images.indices.contains(seam.topIndex) else { return }
                withAnimation {
                    proxy.scrollTo(images[seam.topIndex].id, anchor: .center)
                }
            }
        }
    }

    private func isSeamEndpoint(_ index: Int) -> Bool {
        guard let seam = highlightedSeam else { return false }
        return index == seam.topIndex || index == seam.bottomIndex
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
    let isHighlighted: Bool
    let isDisabled: Bool
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
                            .stroke(
                                isHighlighted ? Color.orange : Color.secondary.opacity(0.3),
                                lineWidth: isHighlighted ? 2.5 : 1
                            )
                    )

                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white, .black.opacity(0.5))
                }
                .padding(4)
                .disabled(isDisabled)
                .accessibilityLabel("删除第 \(index + 1) 张")
            }

            HStack(spacing: 16) {
                Button(action: onMoveLeft) {
                    Image(systemName: "chevron.left.circle")
                }
                .disabled(isDisabled || index == 0)
                .accessibilityLabel("左移")

                Text("\(index + 1)")
                    .font(isHighlighted ? .caption.bold().monospacedDigit() : .caption.monospacedDigit())
                    .foregroundStyle(isHighlighted ? .orange : .secondary)

                Button(action: onMoveRight) {
                    Image(systemName: "chevron.right.circle")
                }
                .disabled(isDisabled || index == count - 1)
                .accessibilityLabel("右移")
            }
            .font(.body)
        }
    }
}
