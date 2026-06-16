// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import PhotosUI

/// Main screen (v1 flow): pick screenshots, then reorder/trim/stitch/preview via `StitchReviewView`.
struct ContentView: View {
    @StateObject private var model = StitchViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if model.images.isEmpty {
                    emptyState
                    Spacer(minLength: 0)
                    picker
                        .padding(.horizontal)
                        .padding(.bottom)
                } else {
                    StitchReviewView(model: model)
                    picker
                        .padding(.horizontal)
                        .padding(.bottom)
                }
            }
            .navigationTitle("驿站截图")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !model.images.isEmpty {
                        Button("清空") { model.clear() }
                    }
                }
            }
        }
    }

    // MARK: - Sections

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("选择多张截图,自动拼接成一张长图")
                .font(.headline)
            Text("先用系统截图截好若干张,再到这里选中拼接")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxHeight: .infinity)
    }

    private var picker: some View {
        PhotosPicker(
            selection: $model.pickerItems,
            maxSelectionCount: 20,
            matching: .images
        ) {
            Label(model.images.isEmpty ? "选择截图" : "重新选择",
                  systemImage: "photo.on.rectangle.angled")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(model.isStitching)
    }
}
