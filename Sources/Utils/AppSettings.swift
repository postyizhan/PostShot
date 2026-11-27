// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Combine
import CoreGraphics

/// Maps the three user-facing export format choices to `ImageExporter.ImageFormat`.
enum ExportFormat: String, CaseIterable, Identifiable, Codable {
    case png
    case heic
    case jpeg

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .png:  return "PNG 无损"
        case .heic: return "HEIC 省空间"
        case .jpeg: return "JPEG 高清"
        }
    }

    var shortName: String {
        switch self {
        case .png:  return "PNG"
        case .heic: return "HEIC"
        case .jpeg: return "JPEG"
        }
    }

    var fileExtension: String {
        switch self {
        case .png:  return "png"
        case .heic: return "heic"
        case .jpeg: return "jpg"
        }
    }

    var supportsQuality: Bool { self != .png }

    var imageFormat: ImageExporter.ImageFormat {
        switch self {
        case .png:  return .png
        case .heic: return .heic(quality: 0.85)
        case .jpeg: return .jpeg(quality: 0.9)
        }
    }

    func imageFormat(quality: Double) -> ImageExporter.ImageFormat {
        let clamped = min(max(quality, 0.1), 1.0)
        switch self {
        case .png:  return .png
        case .heic: return .heic(quality: CGFloat(clamped))
        case .jpeg: return .jpeg(quality: CGFloat(clamped))
        }
    }
}

/// Export DPI metadata options for stitched output.
enum ExportDPI: Int, CaseIterable, Identifiable, Codable {
    case original = 0
    case dpi72 = 72
    case dpi144 = 144
    case dpi300 = 300

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .original: return "原图默认"
        case .dpi72:    return "72 DPI"
        case .dpi144:   return "144 DPI"
        case .dpi300:   return "300 DPI"
        }
    }

    var shortLabel: String {
        switch self {
        case .original: return "原图"
        case .dpi72:    return "72"
        case .dpi144:   return "144"
        case .dpi300:   return "300"
        }
    }
}

/// Cleanup policy for source screenshots and temporary recording frames after export.
enum OriginalCleanupPolicy: String, CaseIterable, Identifiable, Codable {
    case keep
    case recentlyDeleted
    case immediateCacheOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .keep:               return "保留原图"
        case .recentlyDeleted:    return "移入系统最近删除"
        case .immediateCacheOnly: return "优先清理（相册进最近删除）"
        }
    }

    var subtitle: String {
        switch self {
        case .keep:
            return "导出后保留相册中的原始截图，录制临时帧缓存会在结束时自动清理。"
        case .recentlyDeleted:
            return "导出后请求将相册原图移入系统「最近删除」（需系统确认），录制临时帧缓存同步清理。"
        case .immediateCacheOnly:
            return "录制临时帧缓存会立即彻底清理；相册原图受 iOS Photos 机制限制仍会移入「最近删除」（需系统确认）。"
        }
    }
}

/// Persistent app-wide preferences backed by `UserDefaults`.
///
/// Pass a custom `UserDefaults` for unit tests (e.g. `UserDefaults(suiteName: "test")`).
@MainActor
final class AppSettings: ObservableObject {

    private enum Keys {
        static let hasCompletedOnboarding     = "settings.hasCompletedOnboarding"
        static let deleteOriginalsAfterExport = "settings.deleteOriginalsAfterExport"
        static let saveStitchedOnShare        = "settings.saveStitchedOnShare"
        static let defaultExportFormat        = "settings.defaultExportFormat"
        static let soundEnabled               = "settings.soundEnabled"
        static let hapticsEnabled             = "settings.hapticsEnabled"
        static let exportQuality              = "settings.exportQuality"
        static let exportDPI                  = "settings.exportDPI"
        static let targetAlbumName            = "settings.targetAlbumName"
        static let originalCleanupPolicy      = "settings.originalCleanupPolicy"
        static let autoStopOnScrollIdle       = "settings.autoStopOnScrollIdle"
        static let scrollIdleStopSeconds      = "settings.scrollIdleStopSeconds"
        static let removeScrollIndicatorByDefault = "settings.removeScrollIndicatorByDefault"
    }

    private static let allowedScrollIdleSeconds: Set<Int> = [2, 3, 5, 8]

    private let defaults: UserDefaults
    private var isSyncingCleanup = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hasCompletedOnboarding     = defaults.bool(forKey: Keys.hasCompletedOnboarding)
        let legacyDeleteOriginals       = defaults.bool(forKey: Keys.deleteOriginalsAfterExport)
        self.saveStitchedOnShare        = defaults.bool(forKey: Keys.saveStitchedOnShare)
        let rawFormat = defaults.string(forKey: Keys.defaultExportFormat) ?? ""
        self.defaultExportFormat        = ExportFormat(rawValue: rawFormat) ?? .png
        // Bool defaults: sound and haptics are ON unless the user has explicitly turned them off.
        self.soundEnabled   = defaults.object(forKey: Keys.soundEnabled)   as? Bool ?? true
        self.hapticsEnabled = defaults.object(forKey: Keys.hapticsEnabled) as? Bool ?? true

        let storedQuality = defaults.object(forKey: Keys.exportQuality) != nil
            ? defaults.double(forKey: Keys.exportQuality)
            : 0.85
        self.exportQuality = Self.clampQuality(storedQuality)

        let rawDPI = defaults.object(forKey: Keys.exportDPI) as? Int
        self.exportDPI = rawDPI.flatMap(ExportDPI.init(rawValue:)) ?? .original
        self.targetAlbumName = defaults.string(forKey: Keys.targetAlbumName) ?? ""

        let resolvedPolicy = Self.resolveInitialCleanupPolicy(
            defaults: defaults,
            legacyDeleteOriginals: legacyDeleteOriginals
        )
        self.originalCleanupPolicy = resolvedPolicy
        self.deleteOriginalsAfterExport = (resolvedPolicy != .keep)

        self.autoStopOnScrollIdle = defaults.bool(forKey: Keys.autoStopOnScrollIdle)
        let storedIdleSeconds = defaults.object(forKey: Keys.scrollIdleStopSeconds) as? Int ?? 3
        self.scrollIdleStopSeconds = Self.normalizeScrollIdleSeconds(storedIdleSeconds)
        self.removeScrollIndicatorByDefault = defaults.object(forKey: Keys.removeScrollIndicatorByDefault) as? Bool ?? true
    }

    // MARK: - Published properties (each persists on write via didSet)

    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }

    /// After saving or sharing, offer to move the source screenshots to Recently Deleted.
    @Published var deleteOriginalsAfterExport: Bool {
        didSet {
            defaults.set(deleteOriginalsAfterExport, forKey: Keys.deleteOriginalsAfterExport)
            syncPolicyFromDeleteFlag()
        }
    }

    /// When sharing, also save a copy to the photo album.
    @Published var saveStitchedOnShare: Bool {
        didSet { defaults.set(saveStitchedOnShare, forKey: Keys.saveStitchedOnShare) }
    }

    @Published var defaultExportFormat: ExportFormat {
        didSet { defaults.set(defaultExportFormat.rawValue, forKey: Keys.defaultExportFormat) }
    }

    @Published var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: Keys.soundEnabled) }
    }

    @Published var hapticsEnabled: Bool {
        didSet { defaults.set(hapticsEnabled, forKey: Keys.hapticsEnabled) }
    }

    @Published var exportQuality: Double {
        didSet {
            let clamped = Self.clampQuality(exportQuality)
            if exportQuality != clamped {
                exportQuality = clamped
                return
            }
            defaults.set(clamped, forKey: Keys.exportQuality)
        }
    }

    @Published var exportDPI: ExportDPI {
        didSet { defaults.set(exportDPI.rawValue, forKey: Keys.exportDPI) }
    }

    @Published var targetAlbumName: String {
        didSet { defaults.set(targetAlbumName, forKey: Keys.targetAlbumName) }
    }

    var targetAlbumDisplayName: String {
        targetAlbumName.isEmpty ? "所有照片" : targetAlbumName
    }

    @Published var originalCleanupPolicy: OriginalCleanupPolicy {
        didSet {
            defaults.set(originalCleanupPolicy.rawValue, forKey: Keys.originalCleanupPolicy)
            syncDeleteFlagFromPolicy()
        }
    }

    @Published var autoStopOnScrollIdle: Bool {
        didSet { defaults.set(autoStopOnScrollIdle, forKey: Keys.autoStopOnScrollIdle) }
    }

    @Published var scrollIdleStopSeconds: Int {
        didSet {
            let normalized = Self.normalizeScrollIdleSeconds(scrollIdleStopSeconds)
            if scrollIdleStopSeconds != normalized {
                scrollIdleStopSeconds = normalized
                return
            }
            defaults.set(normalized, forKey: Keys.scrollIdleStopSeconds)
        }
    }

    @Published var removeScrollIndicatorByDefault: Bool {
        didSet { defaults.set(removeScrollIndicatorByDefault, forKey: Keys.removeScrollIndicatorByDefault) }
    }

    // MARK: - Helpers

    private func syncPolicyFromDeleteFlag() {
        guard !isSyncingCleanup else { return }
        isSyncingCleanup = true
        defer { isSyncingCleanup = false }
        if deleteOriginalsAfterExport {
            if originalCleanupPolicy == .keep {
                originalCleanupPolicy = .recentlyDeleted
            }
        } else if originalCleanupPolicy != .keep {
            originalCleanupPolicy = .keep
        }
    }

    private func syncDeleteFlagFromPolicy() {
        guard !isSyncingCleanup else { return }
        isSyncingCleanup = true
        defer { isSyncingCleanup = false }
        let shouldDelete = (originalCleanupPolicy != .keep)
        if deleteOriginalsAfterExport != shouldDelete {
            deleteOriginalsAfterExport = shouldDelete
        }
    }

    private static func clampQuality(_ value: Double) -> Double {
        min(max(value, 0.1), 1.0)
    }

    private static func normalizeScrollIdleSeconds(_ seconds: Int) -> Int {
        allowedScrollIdleSeconds.contains(seconds) ? seconds : 3
    }

    private static func resolveInitialCleanupPolicy(
        defaults: UserDefaults,
        legacyDeleteOriginals: Bool
    ) -> OriginalCleanupPolicy {
        if let rawPolicy = defaults.string(forKey: Keys.originalCleanupPolicy),
           let parsed = OriginalCleanupPolicy(rawValue: rawPolicy) {
            return parsed
        }
        return legacyDeleteOriginals ? .recentlyDeleted : .keep
    }
}
