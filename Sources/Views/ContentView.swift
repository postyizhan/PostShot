// SPDX-License-Identifier: AGPL-3.0-or-later
import Photos
import PhotosUI
import SwiftUI

/// Unified Home screen (拼图 tab): content-first 2-column auto-discovered screenshot gallery
/// paired with a thumb-reachable floating PhotosPicker capsule.
struct ContentView: View {
    @Binding var selectedTab: Int

    @StateObject private var model = StitchViewModel(autoSuggestCrop: true)
    @StateObject private var autoModel = AutoStitchViewModel()
    @State private var preparedAutoModel: StitchViewModel?
    @State private var showManualEditor = false
    @State private var showAutoEditor = false
    @State private var showSettings = false
    @State private var showClearConfirm = false
    @State private var photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase

    private let gridColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    init(selectedTab: Binding<Int> = .constant(0)) {
        _selectedTab = selectedTab
    }

    var body: some View {
        NavigationStack {
            mainScrollView
                .background(Color(.systemGroupedBackground).ignoresSafeArea())
                .navigationTitle("驿站截图")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape")
                                .foregroundStyle(.primary)
                        }
                        .accessibilityLabel("设置")
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    floatingPickerInset
                }
                .navigationDestination(isPresented: $showManualEditor) {
                    StitchEditorView(model: model, allowReselectPicker: true) {
                        showManualEditor = false
                    }
                    .environmentObject(settings)
                }
                .navigationDestination(isPresented: $showAutoEditor) { autoEditorDestination }
                .sheet(isPresented: $showSettings) {
                    SettingsView().environmentObject(settings)
                }
                .overlay {
                    if autoModel.isPreparingSession { preparingOverlay }
                }
                .alert("加载失败", isPresented: $model.isShowingError, presenting: model.errorMessage) { _ in
                    Button("好", role: .cancel) {}
                } message: { Text($0) }
        }
        .alert("无法准备截图", isPresented: $autoModel.isShowingError, presenting: autoModel.errorMessage) { _ in
            Button("好", role: .cancel) {}
        } message: { Text($0) }
        .onChange(of: model.images) { newImages in
            if !newImages.isEmpty && !showManualEditor { showManualEditor = true }
        }
        .task { refreshPhotoStatusAndDiscoverIfAuthorized() }
        .onChange(of: settings.hasCompletedOnboarding) { completed in
            if completed { refreshPhotoStatusAndDiscoverIfAuthorized() }
        }
        .onChange(of: scenePhase) { handleScenePhase($0) }
    }

    // MARK: - Main Content

    private var mainScrollView: some View {
        ScrollView {
            VStack(spacing: 16) {
                if !model.images.isEmpty { resumeEditingCard }
                if photoStatus == .denied || photoStatus == .restricted { permissionCard }
                sessionsContent
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .refreshable { await autoModel.discover() }
    }

    @ViewBuilder
    private var autoEditorDestination: some View {
        if let prepared = preparedAutoModel {
            StitchEditorView(model: prepared, allowReselectPicker: false) {
                showAutoEditor = false
            }
            .environmentObject(settings)
        }
    }

    // MARK: - Floating Picker

    private var floatingPickerInset: some View {
        HStack {
            Spacer()
            PhotosPicker(
                selection: $model.pickerItems,
                maxSelectionCount: 20,
                matching: .images,
                photoLibrary: .shared()
            ) {
                Label("从相册选图", systemImage: "photo.on.rectangle.angled")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DesignTokens.onInk)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
                    .background(DesignTokens.ink, in: Capsule())
                    .shadow(color: Color.black.opacity(0.16), radius: 14, y: 6)
            }
            .disabled(model.isStitching)
            .opacity(model.isStitching ? 0.45 : 1)
            Spacer()
        }
        .padding(.bottom, 10)
    }

    // MARK: - Status Banners

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("相册权限未开启")
                    .font(.subheadline.weight(.semibold))
                Text("自动发现连续截屏与相册选图需要读取权限。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 8) {
                Button("前往系统设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(AppleSecondaryButtonStyle())

                Button("改用滚动录屏") { selectedTab = 1 }
                    .buttonStyle(ApplePrimaryButtonStyle())
            }
        }
        .padding(16)
        .appleCard()
    }

    private var resumeEditingCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(DesignTokens.inkSubtle, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("继续编辑 \(model.images.count) 张截图")
                    .font(.subheadline.weight(.semibold))
                Text("恢复调整顺序、裁边与拼接")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("清空") { showClearConfirm = true }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .disabled(model.isStitching)
                .confirmationDialog("清空已选截图？", isPresented: $showClearConfirm, titleVisibility: .visible) {
                    Button("清空截图", role: .destructive) { model.clear() }
                    Button("取消", role: .cancel) {}
                }
            Button("继续") { showManualEditor = true }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(DesignTokens.ink, in: Capsule())
                .foregroundStyle(DesignTokens.onInk)
        }
        .padding(14)
        .appleCard()
    }

    // MARK: - Sessions Gallery

    @ViewBuilder
    private var sessionsContent: some View {
        switch autoModel.state {
        case .idle:
            if photoStatus == .authorized || photoStatus == .limited {
                loadingStateView
            } else {
                needPhotoAccessStateView
            }
        case .loading:
            loadingStateView
        case .loaded(let sessions):
            groupedGallery(sessions)
        case .empty:
            emptyStateView
        case .denied:
            if photoStatus == .denied || photoStatus == .restricted {
                EmptyView()
            } else {
                needPhotoAccessStateView
            }
        }
    }

    private var loadingStateView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("正在查找最近的截图…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 96)
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            AppleEmptyStateView(
                systemImage: "rectangle.stack",
                title: "暂无连续截屏",
                subtitle: "连续截取同一页面 2 张以上会自动汇总在此，也可点击下方直接从相册选图。"
            )
            Button("改用滚动录屏") { selectedTab = 1 }
                .buttonStyle(AppleGhostButtonStyle())
                .frame(maxWidth: 240)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 44)
    }

    private var needPhotoAccessStateView: some View {
        VStack(spacing: 14) {
            AppleEmptyStateView(
                systemImage: "photo.on.rectangle.angled",
                title: "授权相册自动发现截图",
                subtitle: "允许读取照片后会自动聚合连续截屏；暂不授权也可点击下方选图或改用录屏。"
            )
            VStack(spacing: 8) {
                if photoStatus == .notDetermined {
                    Button("允许访问相册") { requestPhotosFromHome() }
                        .buttonStyle(ApplePrimaryButtonStyle())
                }
                Button("改用滚动录屏") { selectedTab = 1 }
                    .buttonStyle(AppleSecondaryButtonStyle())
            }
            .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 32)
    }

    private func groupedGallery(_ sessions: [ScreenshotGrouping.ScreenshotSession]) -> some View {
        let sections = groupedSections(from: sessions)
        return LazyVStack(alignment: .leading, spacing: 22) {
            ForEach(sections) { section in
                sectionBlock(section)
            }
        }
    }

    private func sectionBlock(_ section: SessionDaySection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            LazyVGrid(columns: gridColumns, spacing: 12) {
                ForEach(section.sessions) { session in
                    sessionGridCard(session)
                }
            }
        }
    }

    private func sessionGridCard(_ session: ScreenshotGrouping.ScreenshotSession) -> some View {
        SessionGridCard(session: session, height: 224) {
            Task {
                if let prepared = await autoModel.makeStitchModel(for: session) {
                    preparedAutoModel = prepared
                    showAutoEditor = true
                }
            }
        }
        .disabled(autoModel.isPreparingSession)
    }

    private var preparingOverlay: some View {
        ZStack {
            Color.black.opacity(0.22).ignoresSafeArea()
            ProgressView("正在载入这组截图…")
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    // MARK: - Helpers

    private func handleScenePhase(_ newPhase: ScenePhase) {
        guard newPhase == .active else { return }
        refreshPhotoStatusAndDiscoverIfAuthorized()
    }

    private func refreshPhotoStatusAndDiscoverIfAuthorized() {
        let latest = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        photoStatus = latest
        guard settings.hasCompletedOnboarding,
              latest == .authorized || latest == .limited else { return }
        Task { await autoModel.discover() }
    }

    private func requestPhotosFromHome() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            DispatchQueue.main.async {
                photoStatus = status
                if status == .authorized || status == .limited {
                    Task { await autoModel.discover() }
                }
            }
        }
    }

    private func groupedSections(
        from sessions: [ScreenshotGrouping.ScreenshotSession]
    ) -> [SessionDaySection] {
        let calendar = Calendar.current
        var today: [ScreenshotGrouping.ScreenshotSession] = []
        var yesterday: [ScreenshotGrouping.ScreenshotSession] = []
        var earlier: [ScreenshotGrouping.ScreenshotSession] = []

        for session in sessions {
            if calendar.isDateInToday(session.startDate) {
                today.append(session)
            } else if calendar.isDateInYesterday(session.startDate) {
                yesterday.append(session)
            } else {
                earlier.append(session)
            }
        }

        return [
            SessionDaySection(id: "today", title: "今天", sessions: today),
            SessionDaySection(id: "yesterday", title: "昨天", sessions: yesterday),
            SessionDaySection(id: "earlier", title: "更早", sessions: earlier),
        ].filter { !$0.sessions.isEmpty }
    }
}

private struct SessionDaySection: Identifiable {
    let id: String
    let title: String
    let sessions: [ScreenshotGrouping.ScreenshotSession]
}
