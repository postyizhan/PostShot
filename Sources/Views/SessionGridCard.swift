// SPDX-License-Identifier: AGPL-3.0-or-later
import Photos
import SwiftUI

/// Gallery thumbnail card representing a discoverable screenshot session on the Home tab.
struct SessionGridCard: View {
    let session: ScreenshotGrouping.ScreenshotSession
    var height: CGFloat = 224
    let action: () -> Void
    @State private var thumbnail: UIImage?

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottom) {
                thumbnailLayer
                LinearGradient(
                    colors: [.clear, .black.opacity(0.48)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                HStack(alignment: .bottom, spacing: 6) {
                    Text(timeSummary)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(session.count)张")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .padding(9)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .task(id: session.id) {
            guard let firstID = session.items.first?.id else { return }
            thumbnail = await SessionThumbnailLoader.loadThumbnail(
                assetID: firstID,
                targetSize: CGSize(width: 360, height: 480)
            )
        }
    }

    @ViewBuilder
    private var thumbnailLayer: some View {
        if let thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Rectangle()
                .fill(Color(.tertiarySystemGroupedBackground))
                .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
        }
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
