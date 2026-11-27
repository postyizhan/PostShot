// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import Photos

/// "自动" tab: discovers bursts of system screenshots and stitches a chosen session.
struct AutoStitchView: View {
    @Binding var selectedTab: Int

    @StateObject private var model = AutoStitchViewModel()
    @State private var preparedModel: StitchViewModel?
    @State private var showReview = false
    @State private var showSettings = false
    @State private var showTutorial = false
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase

    init(selectedTab: Binding<Int> = .constant(1)) {
        _selectedTab = selectedTab
    }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground).ignoresSafeArea())
                .navigationTitle("自动拼接")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) { toolbarButtons }
                }
                .navigationDestination(isPresented: $showReview) {
                    if let m = preparedModel {
                        StitchEditorView(model: m, allowReselectPicker: false) { showReview = false }
                            .environmentObject(settings)
                    }
                }
                .sheet(isPresented: $showSettings) { SettingsView().environmentObject(settings) }
                .sheet(isPresented: $showTutorial) { GuideTutorialSheet(mode: .auto) }
        }
        .task {
            guard settings.hasCompletedOnboarding else { return }
            await model.discover()
        }
        .onChange(of: settings.hasCompletedOnboarding) { completed in
            if completed && model.state == .idle {
                Task { await model.discover() }
            }
        }
        .onChange(of: scenePhase) { newPhase in
            guard newPhase == .active, model.state == .denied else { return }
            Task { await model.discover() }
        }
        .alert("无法准备截图", isPresented: $model.isShowingError, presenting: model.errorMessage) { _ in
            Button("好", role: .cancel) {}
        } message: { Text($0) }
    }

    private var toolbarButtons: some View {
        HStack(spacing: 8) {
            LightCircleButton(systemImage: "questionmark", accessibilityLabel: "使用教程") { showTutorial = true }
            LightCircleButton(systemImage: "gearshape", accessibilityLabel: "设置") { showSettings = true }
        }
    }

    // MARK: - Content Switcher

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView("正在查找最近的截图…")
        case .denied:
            deniedView
        case .empty:
            emptyView
        case .loaded(let sessions):
            sessionList(sessions)
        }
    }

    // MARK: - States

    private var deniedView: some View {
        ScrollView {
            VStack(spacing: 16) {
                AppleEmptyStateView(
                    systemImage: "photo.on.rectangle.angled",
                    title: "需要相册读取权限",
                    subtitle: "请在系统设置中允许 PostShot 读取照片，以便自动发现连续截屏并恢复滚动顺序。"
                )

                VStack(spacing: 12) {
                    Button("前往系统设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .buttonStyle(ApplePrimaryButtonStyle())

                    Button("改用滚动录屏") {
                        selectedTab = 2
                    }
                    .buttonStyle(AppleSecondaryButtonStyle())
                }
                .frame(maxWidth: 300)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
            .padding(.horizontal, 20)
        }
    }

    private var emptyView: some View {
        ScrollView {
            AppleEmptyStateView(
                systemImage: "sparkles.rectangle.stack",
                title: "没找到可拼接的截图",
                subtitle: "连续截 2 张以上同一页面的滚动截图，下拉即可自动聚合并一键拼接。"
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 56)
        }
        .refreshable {
            await model.discover()
        }
    }

    // MARK: - Grouped Session List

    private func sessionList(_ sessions: [ScreenshotGrouping.ScreenshotSession]) -> some View {
        let sections = groupedSections(from: sessions)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(sections) { section in
                    sectionBlock(section)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .refreshable {
            await model.discover()
        }
        .overlay {
            if model.isPreparingSession {
                preparingOverlay
            }
        }
    }

    private func sectionBlock(_ section: SessionDaySection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            VStack(spacing: 10) {
                ForEach(section.sessions) { session in
                    sessionCard(session)
                }
            }
        }
    }

    private func sessionCard(_ session: ScreenshotGrouping.ScreenshotSession) -> some View {
        Button {
            Task {
                if let prepared = await model.makeStitchModel(for: session) {
                    preparedModel = prepared
                    showReview = true
                }
            }
        } label: {
            HStack(spacing: 14) {
                SessionThumbnailStack(session: session)

                VStack(alignment: .leading, spacing: 5) {
                    Text("\(session.count) 张截图")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(sessionTimeSummary(session))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if let first = session.items.first {
                        Text("\(first.pixelWidth) × \(first.pixelHeight)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .appleCard(cornerRadius: 18)
        }
        .buttonStyle(.plain)
        .disabled(model.isPreparingSession)
    }

    private var preparingOverlay: some View {
        ZStack {
            Color.black.opacity(0.22).ignoresSafeArea()
            ProgressView("正在载入这组截图…")
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: Color.black.opacity(0.15), radius: 16, y: 6)
        }
    }

    // MARK: - Helpers

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

    private func sessionTimeSummary(_ session: ScreenshotGrouping.ScreenshotSession) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(session.startDate) || calendar.isDateInYesterday(session.startDate) {
            return session.startDate.formatted(.dateTime.hour().minute())
        }
        return session.startDate.formatted(.dateTime.month().day().hour().minute())
    }
}

private struct SessionDaySection: Identifiable {
    let id: String
    let title: String
    let sessions: [ScreenshotGrouping.ScreenshotSession]
}

// MARK: - Fanned Thumbnail Stack

/// Loads and displays up to 3 fanned stacked thumbnails for a screenshot session asynchronously.
private struct SessionThumbnailStack: View {
    let session: ScreenshotGrouping.ScreenshotSession
    @State private var thumbs: [UIImage] = []

    private let thumbWidth: CGFloat = 46
    private let thumbHeight: CGFloat = 76
    private let maxThumbs = 3

    var body: some View {
        ZStack {
            if thumbs.isEmpty {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: thumbWidth, height: thumbHeight)
            } else {
                ForEach(Array(thumbs.prefix(maxThumbs).enumerated()), id: \.offset) { index, img in
                    stackedThumb(img, index: index)
                }
            }
        }
        .frame(width: thumbWidth + 16, height: thumbHeight + 10)
        .task(id: session.id) {
            await loadThumbs()
        }
    }

    private func stackedThumb(_ img: UIImage, index: Int) -> some View {
        let angle = Double(index - 1) * 4.0
        let xOffset = CGFloat(index) * 5.0 - 4.0
        let yOffset = CGFloat(index) * -3.0 + 3.0
        return Image(uiImage: img)
            .resizable()
            .scaledToFill()
            .frame(width: thumbWidth, height: thumbHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.55), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.16), radius: 4, x: 0, y: 2)
            .rotationEffect(.degrees(angle))
            .offset(x: xOffset, y: yOffset)
            .zIndex(Double(maxThumbs - index))
    }

    private func loadThumbs() async {
        let ids = Array(session.items.prefix(maxThumbs).map(\.id))
        var loaded: [UIImage] = []
        for id in ids {
            if let img = await SessionThumbnailLoader.loadThumbnail(
                assetID: id,
                targetSize: CGSize(width: 120, height: 200)
            ) {
                loaded.append(img)
            }
        }
        thumbs = loaded
    }
}

// MARK: - Shared Thumbnail Loader

/// Thread-safe async loader for Photos asset thumbnails used by Home and Auto discovery grids.
enum SessionThumbnailLoader {
    static func loadThumbnail(assetID: String, targetSize: CGSize) async -> UIImage? {
        guard let asset = ScreenshotLibrary.asset(for: assetID) else { return nil }
        return await withCheckedContinuation { continuation in
            let lock = NSLock()
            var didResume = false
            let finish: (UIImage?) -> Void = { image in
                lock.lock()
                let shouldResume = !didResume
                didResume = true
                lock.unlock()
                if shouldResume {
                    continuation.resume(returning: image)
                }
            }

            let opts = PHImageRequestOptions()
            opts.deliveryMode = .fastFormat
            opts.resizeMode = .fast
            opts.isNetworkAccessAllowed = false
            opts.isSynchronous = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: opts
            ) { img, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let hasError = info?[PHImageErrorKey] != nil
                if !isDegraded || isCancelled || hasError || img == nil {
                    finish(img)
                }
            }
        }
    }
}
