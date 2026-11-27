// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import PhotosUI
import Photos

/// Main screen (拼图 tab): hero photo picker, recent auto-discovered screenshot grid,
/// and quick access to current export configuration.
struct ContentView: View {
    @Binding var selectedTab: Int

    @StateObject private var model = StitchViewModel(autoSuggestCrop: true)
    @StateObject private var autoModel = AutoStitchViewModel()
    @State private var preparedAutoModel: StitchViewModel?
    @State private var showManualEditor = false
    @State private var showAutoEditor = false
    @State private var showSettings = false
    @State private var showTutorial = false
    @State private var showClearConfirm = false
    @State private var photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase

    init(selectedTab: Binding<Int> = .constant(0)) {
        _selectedTab = selectedTab
    }

    var body: some View {
        NavigationStack {
            mainScrollView
                .background(Color(.systemGroupedBackground).ignoresSafeArea())
                .navigationTitle("驿站截图")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) { toolbarButtons }
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
                .sheet(isPresented: $showTutorial) {
                    GuideTutorialSheet(mode: .manual)
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
        .task {
            refreshPhotoStatusAndDiscoverIfAuthorized()
        }
        .onChange(of: settings.hasCompletedOnboarding) { completed in
            if completed { refreshPhotoStatusAndDiscoverIfAuthorized() }
        }
        .onChange(of: scenePhase) { handleScenePhase($0) }
    }

    private var mainScrollView: some View {
        ScrollView {
            VStack(spacing: 16) {
                if photoStatus == .denied || photoStatus == .restricted { permissionCard }
                if !model.images.isEmpty { resumeEditingCard }
                heroPickCard
                recentSessionsSection
                exportConfigStrip
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
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

    // MARK: - Toolbar & Status Cards

    private var toolbarButtons: some View {
        HStack(spacing: 4) {
            Button {
                showTutorial = true
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(DesignTokens.accentBlue)
            }
            .accessibilityLabel("使用教程")

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(DesignTokens.accentBlue)
            }
            .accessibilityLabel("设置")
        }
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                SettingsIconBadge(systemImage: "photo.badge.exclamationmark", color: .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("相册权限未开启").font(.subheadline.weight(.semibold))
                    Text("自动发现连续截屏与相册选图需要读取权限。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 8) {
                Button("前往系统设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(AppleSecondaryButtonStyle())

                Button("改用滚动录屏") { selectedTab = 2 }
                    .buttonStyle(ApplePrimaryButtonStyle())
            }
        }
        .padding(16)
        .appleCard()
    }

    private var resumeEditingCard: some View {
        HStack(spacing: 12) {
            SettingsIconBadge(systemImage: "square.stack.3d.up.fill", color: DesignTokens.accentBlue)
            VStack(alignment: .leading, spacing: 2) {
                Text("继续编辑当前 \(model.images.count) 张截图").font(.subheadline.weight(.semibold))
                Text("点按恢复调整顺序、裁边与拼接").font(.caption).foregroundStyle(.secondary)
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
                .background(DesignTokens.accentBlue, in: Capsule())
                .foregroundStyle(.white)
        }
        .padding(14)
        .appleCard()
    }

    // MARK: - Hero Pick Card

    private var heroPickCard: some View {
        VStack(spacing: 16) {
            heroIconStack
            VStack(spacing: 6) {
                Text("选择多张截图拼接").font(.title3.weight(.semibold))
                Text("支持相册多选或从下方直接点开最近截屏")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            PhotosPicker(
                selection: $model.pickerItems,
                maxSelectionCount: 20,
                matching: .images,
                photoLibrary: .shared()
            ) {
                Label("从相册选择截图", systemImage: "photo.on.rectangle.angled")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(DesignTokens.accentBlue, in: Capsule())
            }
            .disabled(model.isStitching)
            .opacity(model.isStitching ? 0.45 : 1)
        }
        .padding(20)
        .appleCard()
    }

    private var heroIconStack: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DesignTokens.accentBlue.opacity(0.14))
                .frame(width: 52, height: 52).rotationEffect(.degrees(-8)).offset(x: -10, y: 2)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DesignTokens.accentBlue.opacity(0.22))
                .frame(width: 52, height: 52).rotationEffect(.degrees(7)).offset(x: 10, y: 2)
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(DesignTokens.accentBlue)
                .frame(width: 56, height: 56)
                .overlay(Image(systemName: "photo.stack.fill").font(.system(size: 24, weight: .semibold)).foregroundStyle(.white))
                .shadow(color: DesignTokens.accentBlue.opacity(0.28), radius: 10, y: 4)
        }
        .padding(.top, 4)
    }

    // MARK: - Recent Sessions Bento Grid

    private var recentSessionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("最近可拼截图").font(.headline)
                Spacer()
                Button("查看全部") { selectedTab = 1 }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(DesignTokens.accentBlue)
            }
            .padding(.horizontal, 4)
            recentSessionsContent
        }
    }

    @ViewBuilder
    private var recentSessionsContent: some View {
        switch autoModel.state {
        case .idle:
            if photoStatus == .authorized || photoStatus == .limited {
                loadingSessionsCard
            } else {
                needPhotoAccessSessionsCard
            }
        case .loading:
            loadingSessionsCard
        case .loaded(let sessions):
            bentoGrid(Array(sessions.prefix(5)))
        case .empty, .denied:
            VStack(spacing: 6) {
                Image(systemName: "rectangle.stack").font(.title3).foregroundStyle(.secondary)
                Text("暂未检测到最近连续截屏").font(.subheadline.weight(.medium))
                Text("连续截 2 张以上同一页面后，会自动显示在这里。")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 22).padding(.horizontal, 16).appleCard()
        }
    }

    private var loadingSessionsCard: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("正在发现最近截屏…").font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 24).appleCard()
    }

    private var needPhotoAccessSessionsCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.badge.plus").font(.title3).foregroundStyle(DesignTokens.accentBlue)
            Text("授权相册后可自动发现连续截图").font(.subheadline.weight(.medium))
            HStack(spacing: 10) {
                if photoStatus == .notDetermined {
                    Button("允许访问相册") { requestPhotosFromHome() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
                Button("改用滚动录屏") { selectedTab = 2 }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 20).padding(.horizontal, 16).appleCard()
    }

    @ViewBuilder
    private func bentoGrid(_ recent: [ScreenshotGrouping.ScreenshotSession]) -> some View {
        if recent.count == 1 {
            sessionGridCard(recent[0], height: 176)
        } else if !recent.isEmpty {
            VStack(spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    sessionGridCard(recent[0], height: 210)
                    VStack(spacing: 10) {
                        sessionGridCard(recent[1], height: 100)
                        if recent.count > 2 {
                            sessionGridCard(recent[2], height: 100)
                        } else {
                            moreDiscoveryTile
                        }
                    }
                }
                if recent.count > 3 {
                    HStack(spacing: 10) {
                        ForEach(Array(recent.dropFirst(3))) { sessionGridCard($0, height: 112) }
                    }
                }
            }
        }
    }

    private func sessionGridCard(_ session: ScreenshotGrouping.ScreenshotSession, height: CGFloat) -> some View {
        SessionGridCard(session: session, height: height) {
            Task {
                if let prepared = await autoModel.makeStitchModel(for: session) {
                    preparedAutoModel = prepared
                    showAutoEditor = true
                }
            }
        }
        .disabled(autoModel.isPreparingSession)
    }

    private var moreDiscoveryTile: some View {
        Button { selectedTab = 1 } label: {
            VStack(spacing: 4) {
                Image(systemName: "wand.and.stars").font(.headline).foregroundStyle(DesignTokens.accentBlue)
                Text("更多发现").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).frame(height: 100).appleCard(cornerRadius: 16)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Export Configuration Strip

    private var exportConfigStrip: some View {
        Button { showSettings = true } label: {
            HStack(spacing: 12) {
                SettingsIconBadge(systemImage: "slider.horizontal.3", color: DesignTokens.accentBlue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("当前导出配置").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(exportSummaryText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(14).appleCard()
        }
        .buttonStyle(.plain)
    }

    private var exportSummaryText: String {
        let format = settings.defaultExportFormat.shortName
        let detail = settings.defaultExportFormat.supportsQuality ? "\(Int(settings.exportQuality * 100))%" : "无损"
        return "\(format) · \(detail) · \(settings.exportDPI.displayName) · \(settings.targetAlbumDisplayName)"
    }

    private var preparingOverlay: some View {
        ZStack {
            Color.black.opacity(0.22).ignoresSafeArea()
            ProgressView("正在载入这组截图…")
                .padding(.horizontal, 22).padding(.vertical, 18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}
