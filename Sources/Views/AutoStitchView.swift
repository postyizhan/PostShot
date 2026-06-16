// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// Tailor-style "自动" tab: auto-discovers bursts of system screenshots and stitches a chosen
/// session via the shared `StitchReviewView`. System screenshots are pixel-identical in their
/// overlap, so this path produces the cleanest seams (better than v2 video-frame capture).
struct AutoStitchView: View {
    @StateObject private var model = AutoStitchViewModel()
    @State private var preparedModel: StitchViewModel?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("自动拼接")
                .navigationDestination(item: $preparedModel) { stitchModel in
                    StitchReviewView(model: stitchModel)
                        .navigationTitle("审阅截图")
                        .navigationBarTitleDisplayMode(.inline)
                }
        }
        .task { await model.discover() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView("正在查找最近的截图…")
        case .denied:
            message("需要相册访问权限", "请在系统设置里允许 PostShot 读取照片,以便自动发现你的截图。",
                    system: "lock.fill")
        case .empty:
            message("没找到可拼接的截图", "连续截几张同一屏的滚动截图,再回来看看。",
                    system: "photo.on.rectangle")
        case .loaded(let sessions):
            sessionList(sessions)
        }
    }

    private func sessionList(_ sessions: [ScreenshotGrouping.ScreenshotSession]) -> some View {
        List(sessions) { session in
            Button {
                Task { preparedModel = await model.makeStitchModel(for: session) }
            } label: {
                sessionRow(session)
            }
            .disabled(model.isPreparingSession)
        }
        .overlay {
            if model.isPreparingSession {
                ProgressView("正在载入这组截图…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func sessionRow(_ session: ScreenshotGrouping.ScreenshotSession) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.stack.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(session.count) 张截图")
                    .font(.headline)
                Text(session.startDate, format: .dateTime.month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private func message(_ title: String, _ subtitle: String, system: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: system)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
