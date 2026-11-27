// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import PhotosUI

/// Half-sheet for inspecting, reordering, removing, and re-picking source screenshots.
struct SourceFramesSheet: View {
    @ObservedObject var model: StitchViewModel
    @Binding var selectedIndex: Int
    var allowReselectPicker: Bool
    var onPreviewSingle: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    private let cardWidth: CGFloat = 96
    private let cardHeight: CGFloat = 152

    var body: some View {
        NavigationStack {
            Group {
                if model.images.isEmpty && !allowReselectPicker {
                    AppleEmptyStateView(
                        systemImage: "photo.stack",
                        title: "暂无截图素材",
                        subtitle: "返回上一步重新选择或录制截图。"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    framesCarousel
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("素材管理 (\(model.images.count) 张)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private var framesCarousel: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Array(model.images.enumerated()), id: \.element.id) { index, item in
                        frameColumn(item: item, index: index).id(item.id)
                    }
                    if allowReselectPicker { reselectPickerCard }
                }
                .padding(20)
            }
            .onChange(of: selectedIndex) { newIndex in
                guard model.images.indices.contains(newIndex) else { return }
                withAnimation(AppleMotion.gentle) {
                    proxy.scrollTo(model.images[newIndex].id, anchor: .center)
                }
            }
        }
    }

    private func frameColumn(item: SelectedImage, index: Int) -> some View {
        let isSelected = selectedIndex == index
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return VStack(spacing: 10) {
            Button {
                selectedIndex = index
                onPreviewSingle(index)
            } label: {
                Image(uiImage: item.thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: cardWidth, height: cardHeight)
                    .clipShape(shape)
                    .overlay(
                        shape.strokeBorder(
                            isSelected ? DesignTokens.accentBlue : Color.primary.opacity(0.12),
                            lineWidth: isSelected ? 2.5 : 0.8
                        )
                    )
                    .overlay(alignment: .topLeading) { indexBadge(index: index, isSelected: isSelected) }
                    .shadow(color: Color.black.opacity(0.10), radius: 8, y: 4)
            }
            .buttonStyle(.plain)
            .contextMenu { cardContextMenu(for: index) }
            .accessibilityLabel("第 \(index + 1) 张截图，点击放大预览")

            cardActionRow(for: index)
        }
    }

    private func indexBadge(index: Int, isSelected: Bool) -> some View {
        Text("#\(index + 1)")
            .font(.system(size: 11, weight: .bold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(isSelected ? DesignTokens.accentBlue : Color.black.opacity(0.65), in: Capsule())
            .padding(6)
    }

    private func cardActionRow(for index: Int) -> some View {
        HStack(spacing: 6) {
            miniActionButton("arrow.left", label: "左移", isDisabled: index <= 0 || model.isStitching) {
                move(from: index, offset: -1)
            }
            miniActionButton("trash", label: "删除", tint: .red, isDisabled: model.isStitching) {
                removeTile(at: index)
            }
            miniActionButton("arrow.right", label: "右移", isDisabled: index >= model.images.count - 1 || model.isStitching) {
                move(from: index, offset: 1)
            }
        }
    }

    private func miniActionButton(
        _ systemImage: String, label: String, tint: Color = .primary,
        isDisabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isDisabled ? Color.secondary.opacity(0.35) : tint)
                .frame(width: 28, height: 28)
                .background(Color(.secondarySystemGroupedBackground), in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func cardContextMenu(for index: Int) -> some View {
        Button { onPreviewSingle(index) } label: { Label("放大预览", systemImage: "magnifyingglass") }
        Button { move(from: index, offset: -1) } label: { Label("向左移动", systemImage: "arrow.left") }
            .disabled(index <= 0 || model.isStitching)
        Button { move(from: index, offset: 1) } label: { Label("向右移动", systemImage: "arrow.right") }
            .disabled(index >= model.images.count - 1 || model.isStitching)
        Button(role: .destructive) { removeTile(at: index) } label: { Label("删除此图", systemImage: "trash") }
            .disabled(model.isStitching)
    }

    private var reselectPickerCard: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return PhotosPicker(selection: $model.pickerItems, maxSelectionCount: 20, matching: .images, photoLibrary: .shared()) {
            VStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 22, weight: .semibold))
                Text("重选素材").font(.caption.weight(.medium))
            }
            .foregroundStyle(.secondary)
            .frame(width: cardWidth, height: cardHeight)
            .background(Color(.secondarySystemGroupedBackground).opacity(0.65), in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.22), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
        }
        .disabled(model.isStitching)
        .accessibilityLabel("重新选择截图")
    }

    private func move(from index: Int, offset: Int) {
        let target = index + offset
        guard model.images.indices.contains(index), model.images.indices.contains(target) else { return }
        withAnimation(AppleMotion.snappy) {
            model.images.swapAt(index, target)
            selectedIndex = target
        }
    }

    private func removeTile(at index: Int) {
        guard model.images.indices.contains(index) else { return }
        withAnimation(AppleMotion.snappy) {
            model.images.remove(at: index)
            selectedIndex = min(selectedIndex, max(0, model.images.count - 1))
        }
    }
}
