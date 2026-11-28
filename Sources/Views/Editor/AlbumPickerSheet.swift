// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import Photos

/// Sheet allowing users to choose a preset, existing user album, or custom album name
/// for future saved screenshots.
struct AlbumPickerSheet: View {
    @Binding var selectedAlbumName: String

    @Environment(\.dismiss) private var dismiss
    @State private var userAlbumTitles: [String] = []
    @State private var authStatus: PHAuthorizationStatus = .notDetermined
    @State private var customAlbumName: String = ""

    private static let recommendedAlbumName = "驿站截图"

    var body: some View {
        NavigationStack {
            List {
                presetSection
                userAlbumsSection
                customAlbumSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("选择相册")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear(perform: loadAlbums)
        }
        .tint(DesignTokens.ink)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Sections

    private var presetSection: some View {
        Section("预设") {
            albumRow(title: "所有照片（系统默认）", value: "")
            albumRow(title: "驿站截图（推荐相册）", value: Self.recommendedAlbumName)
        }
    }

    private var userAlbumsSection: some View {
        Section("我的相册") {
            if hasPhotoReadAccess {
                if userAlbumTitles.isEmpty {
                    Text("暂无个人相册")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(userAlbumTitles, id: \.self) { title in
                        albumRow(title: title, value: title)
                    }
                }
            } else {
                Text("需要相册读写权限才能列出您的个人相册，您仍可使用预设或自定义相册名。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var customAlbumSection: some View {
        Section {
            HStack(spacing: 10) {
                TextField("输入自定义相册名称", text: $customAlbumName)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .onSubmit(applyCustomAlbumName)

                Button("使用此名称") {
                    applyCustomAlbumName()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(trimmedCustomName.isEmpty)
            }
        } header: {
            Text("自定义相册名")
        } footer: {
            Text("指定相册保存将在后续版本生效，当前已记住您的偏好")
        }
    }

    // MARK: - Helpers

    private func albumRow(title: String, value: String) -> some View {
        Button {
            selectedAlbumName = value
        } label: {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                if selectedAlbumName == value {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
            }
            .contentShape(Rectangle())
        }
    }

    private var hasPhotoReadAccess: Bool {
        authStatus == .authorized || authStatus == .limited
    }

    private var trimmedCustomName: String {
        customAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func applyCustomAlbumName() {
        let name = trimmedCustomName
        guard !name.isEmpty else { return }
        selectedAlbumName = name
        customAlbumName = name
    }

    private func loadAlbums() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        authStatus = status
        if !selectedAlbumName.isEmpty, selectedAlbumName != Self.recommendedAlbumName {
            customAlbumName = selectedAlbumName
        }
        guard status == .authorized || status == .limited else {
            userAlbumTitles = []
            return
        }
        let collections = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .albumRegular,
            options: nil
        )
        var titles: [String] = []
        var seen: Set<String> = []
        collections.enumerateObjects { collection, _, _ in
            guard let title = collection.localizedTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty,
                  seen.insert(title).inserted else { return }
            titles.append(title)
        }
        userAlbumTitles = titles
    }
}
