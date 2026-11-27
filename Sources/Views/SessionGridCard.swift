// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// Bento-style thumbnail card representing a discoverable screenshot session on the Home tab.
struct SessionGridCard: View {
    let session: ScreenshotGrouping.ScreenshotSession
    let height: CGFloat
    let action: () -> Void
    @State private var thumbnail: UIImage?

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottom) {
                thumbnailLayer
                LinearGradient(
                    colors: [.clear, .black.opacity(0.45)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                HStack(alignment: .bottom) {
                    Text(session.startDate, format: .dateTime.hour().minute())
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.92))
                    Spacer(minLength: 4)
                    Text("\(session.count)张")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .padding(8)
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
                targetSize: CGSize(width: 320, height: 420)
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
}
