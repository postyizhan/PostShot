// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Groups consecutive system screenshots into "sessions" that are candidates for stitching into
/// one long screenshot — the Tailor-style auto-discovery flow.
///
/// Pure and Photos-framework-agnostic: it operates on lightweight `ScreenshotMeta` (id + timestamp
/// + pixel size), so the clustering logic is fully unit-testable on CI without a device or photo
/// library. The Photos read layer maps `PHAsset`s into `ScreenshotMeta` and feeds this.
///
/// Heuristic (SPEC: long-screenshot candidates are bursts of same-screen captures): a session is a
/// maximal run of screenshots where each adjacent pair was taken within `maxGap` seconds AND has
/// identical pixel dimensions (same screen / orientation). Runs shorter than `minGroupSize` are
/// dropped — a lone screenshot is not a long-screenshot candidate.
enum ScreenshotGrouping {

    /// Lightweight metadata for one screenshot, decoupled from `PHAsset`.
    struct ScreenshotMeta: Equatable {
        let id: String
        let creationDate: Date
        let pixelWidth: Int
        let pixelHeight: Int
    }

    /// A detected burst of consecutive, same-size screenshots, ordered oldest→newest within the group.
    struct ScreenshotSession: Equatable, Identifiable {
        let items: [ScreenshotMeta]
        var id: String { items.first?.id ?? UUID().uuidString }
        var count: Int { items.count }
        /// When the session started (its earliest screenshot).
        var startDate: Date { items.first?.creationDate ?? .distantPast }
    }

    struct Config {
        /// Max seconds between adjacent screenshots to still count as the same session. Scrolling +
        /// screenshotting is fast, so a modest gap separates distinct capture bursts.
        var maxGap: TimeInterval = 10
        /// Minimum screenshots in a session — fewer than this is not a long-screenshot candidate.
        var minGroupSize: Int = 2

        init() {}
    }

    /// Clusters screenshots into sessions.
    ///
    /// - Parameter metas: screenshots in any order (the function sorts internally).
    /// - Returns: sessions with ≥ `minGroupSize` items, **most-recent session first**; items inside
    ///   each session are oldest→newest (the order `StitchEngine` expects, top→bottom).
    static func group(_ metas: [ScreenshotMeta], config: Config = Config()) -> [ScreenshotSession] {
        guard !metas.isEmpty else { return [] }

        // Sort oldest→newest so adjacency in time maps to adjacency in the array.
        let sorted = metas.sorted { $0.creationDate < $1.creationDate }

        var sessions: [ScreenshotSession] = []
        var current: [ScreenshotMeta] = [sorted[0]]

        for meta in sorted.dropFirst() {
            if let last = current.last, belongsToSameSession(last, meta, config: config) {
                current.append(meta)
            } else {
                appendIfValid(current, to: &sessions, config: config)
                current = [meta]
            }
        }
        appendIfValid(current, to: &sessions, config: config)

        // Most-recent session first (its items stay oldest→newest internally).
        return sessions.sorted { $0.startDate > $1.startDate }
    }

    /// Two adjacent screenshots belong to the same session iff close in time AND identical in size.
    private static func belongsToSameSession(
        _ a: ScreenshotMeta,
        _ b: ScreenshotMeta,
        config: Config
    ) -> Bool {
        let withinGap = b.creationDate.timeIntervalSince(a.creationDate) <= config.maxGap
        let sameSize = a.pixelWidth == b.pixelWidth && a.pixelHeight == b.pixelHeight
        return withinGap && sameSize
    }

    /// Commits a run as a session only if it meets the minimum size.
    private static func appendIfValid(
        _ run: [ScreenshotMeta],
        to sessions: inout [ScreenshotSession],
        config: Config
    ) {
        guard run.count >= config.minGroupSize else { return }
        sessions.append(ScreenshotSession(items: run))
    }
}
