// SPDX-License-Identifier: AGPL-3.0-or-later
import Photos
import SwiftUI

/// Gallery thumbnail card representing a discoverable screenshot session on the Home tab.
struct SessionGridCard: View {
    let session: ScreenshotGrouping.ScreenshotSession
    let action: () -> Void

    @State private var thumbnail: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Button(action: action) {
            Color(.tertiarySystemGroupedBackground)
                .aspectRatio(0.72, contentMode: .fit)
                .overlay {
                    if thumbnail == nil {
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                    }
                }
                .overlay(alignment: .top) {
                    if let thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .clipped()
                .overlay(alignment: .bottom) {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.50)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 84)
                }
                .overlay(alignment: .bottom) {
                    bottomMetadata
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .task(id: "\(session.id)-\(displayScale)") {
            guard let firstID = session.items.first?.id else { return }
            let scale = max(1, displayScale)
            thumbnail = await SessionThumbnailLoader.loadThumbnail(
                assetID: firstID,
                targetSize: CGSize(width: ceil(220 * scale), height: ceil(300 * scale))
            )
        }
    }

    private var bottomMetadata: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Text(timeSummary)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 4)
            Text("\(session.count)张")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .padding(9)
    }

    private var timeSummary: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(session.startDate) || calendar.isDateInYesterday(session.startDate) {
            return session.startDate.formatted(.dateTime.hour().minute())
        }
        return session.startDate.formatted(.dateTime.month().day().hour().minute())
    }
}

/// Thread-safe async loader for Photos asset thumbnails used by Home discovery grid.
enum SessionThumbnailLoader {
    private final class OnceContinuation<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Never>?

        init(_ continuation: CheckedContinuation<T, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: T) {
            lock.lock()
            let cont = continuation
            continuation = nil
            lock.unlock()
            cont?.resume(returning: value)
        }
    }

    static func loadThumbnail(assetID: String, targetSize: CGSize) async -> UIImage? {
        guard let asset = ScreenshotLibrary.asset(for: assetID) else { return nil }
        return await withCheckedContinuation { continuation in
            let once = OnceContinuation(continuation)
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .highQualityFormat
            opts.resizeMode = .exact
            opts.isNetworkAccessAllowed = true
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
                if isDegraded && !isCancelled && !hasError {
                    return
                }
                once.resume(img)
            }
        }
    }
}
