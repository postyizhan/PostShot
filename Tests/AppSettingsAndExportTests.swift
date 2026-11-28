// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
import CoreGraphics
@testable import PostShot

final class AppSettingsAndExportTests: XCTestCase {

    // MARK: - AppSettings defaults

    @MainActor
    func testDefaultValues() async throws {
        let suiteName = "com.postshot.test.settings.\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suiteName)!
        let s = AppSettings(defaults: ud)
        XCTAssertFalse(s.hasCompletedOnboarding)
        XCTAssertFalse(s.deleteOriginalsAfterExport)
        XCTAssertFalse(s.saveStitchedOnShare)
        XCTAssertEqual(s.defaultExportFormat, .png)
        XCTAssertTrue(s.soundEnabled)
        XCTAssertTrue(s.hapticsEnabled)
        ud.removePersistentDomain(forName: suiteName)
    }

    @MainActor
    func testPersistence() async throws {
        let suiteName = "com.postshot.test.settings2.\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suiteName)!
        let s = AppSettings(defaults: ud)
        s.hasCompletedOnboarding = true
        s.defaultExportFormat = .heic
        s.soundEnabled = false

        let s2 = AppSettings(defaults: ud)
        XCTAssertTrue(s2.hasCompletedOnboarding)
        XCTAssertEqual(s2.defaultExportFormat, .heic)
        XCTAssertFalse(s2.soundEnabled)
        ud.removePersistentDomain(forName: suiteName)
    }

    // MARK: - ExportFormat

    func testExportFormatProperties() {
        XCTAssertEqual(ExportFormat.png.fileExtension,  "png")
        XCTAssertEqual(ExportFormat.heic.fileExtension, "heic")
        XCTAssertEqual(ExportFormat.jpeg.fileExtension, "jpg")

        XCTAssertFalse(ExportFormat.png.displayName.isEmpty)
        XCTAssertFalse(ExportFormat.heic.displayName.isEmpty)
        XCTAssertFalse(ExportFormat.jpeg.displayName.isEmpty)

        // Check CaseIterable has 3 cases
        XCTAssertEqual(ExportFormat.allCases.count, 3)
    }

    func testExportFormatImageFormatMapping() {
        // PNG maps to .png (no quality param)
        if case .png = ExportFormat.png.imageFormat { } else { XCTFail("Expected .png") }
        // HEIC maps to .heic(quality:)
        if case .heic(let q) = ExportFormat.heic.imageFormat { XCTAssertGreaterThan(q, 0) } else { XCTFail() }
        // JPEG maps to .jpeg(quality:)
        if case .jpeg(let q) = ExportFormat.jpeg.imageFormat { XCTAssertGreaterThan(q, 0) } else { XCTFail() }
    }

    @MainActor
    func testNewSettingsDefaultValues() async throws {
        let suiteName = "com.postshot.test.settings.defaults.\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suiteName)!
        defer { ud.removePersistentDomain(forName: suiteName) }

        let s = AppSettings(defaults: ud)
        XCTAssertEqual(s.exportQuality, 0.85, accuracy: 0.0001)
        XCTAssertEqual(s.exportDPI, .original)
        XCTAssertEqual(s.targetAlbumName, "")
        XCTAssertEqual(s.targetAlbumDisplayName, "所有照片")
        XCTAssertEqual(s.originalCleanupPolicy, .keep)
        XCTAssertFalse(s.autoStopOnScrollIdle)
        XCTAssertEqual(s.scrollIdleStopSeconds, 3)
        XCTAssertTrue(s.removeScrollIndicatorByDefault)
    }

    @MainActor
    func testNewSettingsPersistenceAndClamping() async throws {
        let suiteName = "com.postshot.test.settings.persist.\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suiteName)!
        defer { ud.removePersistentDomain(forName: suiteName) }

        let s = AppSettings(defaults: ud)
        s.exportQuality = 0.62
        s.exportDPI = .dpi300
        s.targetAlbumName = "长截图"
        s.originalCleanupPolicy = .immediateCacheOnly
        s.autoStopOnScrollIdle = true
        s.scrollIdleStopSeconds = 5
        s.removeScrollIndicatorByDefault = false

        let s2 = AppSettings(defaults: ud)
        XCTAssertEqual(s2.exportQuality, 0.62, accuracy: 0.0001)
        XCTAssertEqual(s2.exportDPI, .dpi300)
        XCTAssertEqual(s2.targetAlbumName, "长截图")
        XCTAssertEqual(s2.targetAlbumDisplayName, "长截图")
        XCTAssertEqual(s2.originalCleanupPolicy, .immediateCacheOnly)
        XCTAssertTrue(s2.deleteOriginalsAfterExport)
        XCTAssertTrue(s2.autoStopOnScrollIdle)
        XCTAssertEqual(s2.scrollIdleStopSeconds, 5)
        XCTAssertFalse(s2.removeScrollIndicatorByDefault)

        s2.exportQuality = 0.01
        XCTAssertEqual(s2.exportQuality, 0.1, accuracy: 0.0001)
        s2.exportQuality = 2.5
        XCTAssertEqual(s2.exportQuality, 1.0, accuracy: 0.0001)
        s2.scrollIdleStopSeconds = 99
        XCTAssertEqual(s2.scrollIdleStopSeconds, 3)
    }

    @MainActor
    func testCleanupPolicyBidirectionalSync() async throws {
        let suiteName = "com.postshot.test.settings.sync.\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suiteName)!
        defer { ud.removePersistentDomain(forName: suiteName) }

        let s = AppSettings(defaults: ud)
        s.deleteOriginalsAfterExport = true
        XCTAssertEqual(s.originalCleanupPolicy, .recentlyDeleted)

        s.deleteOriginalsAfterExport = false
        XCTAssertEqual(s.originalCleanupPolicy, .keep)

        s.originalCleanupPolicy = .immediateCacheOnly
        XCTAssertTrue(s.deleteOriginalsAfterExport)

        s.deleteOriginalsAfterExport = true
        XCTAssertEqual(s.originalCleanupPolicy, .immediateCacheOnly)

        s.originalCleanupPolicy = .keep
        XCTAssertFalse(s.deleteOriginalsAfterExport)
    }

    @MainActor
    func testLegacyDeleteFlagInitializesCleanupPolicy() async throws {
        let suiteName = "com.postshot.test.settings.legacy.\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suiteName)!
        defer { ud.removePersistentDomain(forName: suiteName) }
        ud.set(true, forKey: "settings.deleteOriginalsAfterExport")

        let s = AppSettings(defaults: ud)
        XCTAssertEqual(s.originalCleanupPolicy, .recentlyDeleted)
        XCTAssertTrue(s.deleteOriginalsAfterExport)
    }

    func testExportFormatQualityClampingAndMetadata() {
        XCTAssertEqual(ExportFormat.png.shortName, "PNG")
        XCTAssertEqual(ExportFormat.heic.shortName, "HEIC")
        XCTAssertEqual(ExportFormat.jpeg.shortName, "JPEG")
        XCTAssertFalse(ExportFormat.png.supportsQuality)
        XCTAssertTrue(ExportFormat.heic.supportsQuality)
        XCTAssertTrue(ExportFormat.jpeg.supportsQuality)

        if case .png = ExportFormat.png.imageFormat(quality: 0.5) { } else { XCTFail("Expected .png") }
        if case .heic(let qLow) = ExportFormat.heic.imageFormat(quality: 0.01) {
            XCTAssertEqual(qLow, 0.1, accuracy: 0.0001)
        } else { XCTFail("Expected .heic") }
        if case .heic(let qHigh) = ExportFormat.heic.imageFormat(quality: 1.8) {
            XCTAssertEqual(qHigh, 1.0, accuracy: 0.0001)
        } else { XCTFail("Expected .heic") }
        if case .jpeg(let qMid) = ExportFormat.jpeg.imageFormat(quality: 0.72) {
            XCTAssertEqual(qMid, 0.72, accuracy: 0.0001)
        } else { XCTFail("Expected .jpeg") }
        if case .jpeg(let qMin) = ExportFormat.jpeg.imageFormat(quality: -0.5) {
            XCTAssertEqual(qMin, 0.1, accuracy: 0.0001)
        } else { XCTFail("Expected .jpeg") }
    }

    func testExportDPIAndCleanupPolicyMetadata() {
        XCTAssertEqual(ExportDPI.allCases.map(\.rawValue), [0, 72, 144, 300])
        XCTAssertEqual(ExportDPI.original.displayName, "原图默认")
        XCTAssertEqual(ExportDPI.dpi72.shortLabel, "72")
        XCTAssertEqual(ExportDPI.dpi144.shortLabel, "144")
        XCTAssertEqual(ExportDPI.dpi300.shortLabel, "300")

        for policy in OriginalCleanupPolicy.allCases {
            XCTAssertFalse(policy.displayName.isEmpty)
            XCTAssertFalse(policy.subtitle.isEmpty)
        }
    }

    // MARK: - ImageExporter

    func testExportPNG() throws {
        let image = makeSyntheticImage()
        let data = try ImageExporter.export(image, as: .png)
        XCTAssertFalse(data.isEmpty)
        // PNG magic bytes: 89 50 4E 47
        XCTAssertEqual(data.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
    }

    func testExportJPEG() throws {
        let image = makeSyntheticImage()
        let data = try ImageExporter.export(image, as: .jpeg(quality: 0.8))
        XCTAssertFalse(data.isEmpty)
        // JPEG magic bytes: FF D8
        XCTAssertEqual(data.prefix(2), Data([0xFF, 0xD8]))
    }

    func testExportHEIC() throws {
        let image = makeSyntheticImage()
        // HEIC may not be available on all simulators; skip gracefully
        do {
            let data = try ImageExporter.export(image, as: .heic(quality: 0.85))
            XCTAssertFalse(data.isEmpty)
        } catch ImageExporter.ImageExporterError.encodingFailed {
            // Acceptable on simulators without HEIC encoder
            throw XCTSkip("HEIC encoder unavailable on this simulator")
        }
    }

    func testWriteTemporaryFile() throws {
        let data = Data("hello".utf8)
        let url = try ImageExporter.writeTemporaryFile(data, fileExtension: "txt")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.pathExtension, "txt")
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    // MARK: - Helpers

    private func makeSyntheticImage(width: Int = 64, height: Int = 128) -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // Fill with a gradient so PNG/JPEG actually encode meaningful content
        ctx.setFillColor(CGColor(srgbRed: 0.3, green: 0.6, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.5, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
        return ctx.makeImage()!
    }
}
