// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import PostShot

/// Validates `ScreenshotGrouping` clustering against synthetic screenshot metadata sequences.
/// Pure logic, no Photos framework — runs on CI without a device.
final class ScreenshotGroupingTests: XCTestCase {

    private typealias Meta = ScreenshotGrouping.ScreenshotMeta

    private let base = Date(timeIntervalSince1970: 1_000_000)

    /// Builds a screenshot meta at `base + offset` seconds with the given size.
    private func meta(_ id: String, _ offset: TimeInterval, w: Int = 1170, h: Int = 2532) -> Meta {
        Meta(id: id, creationDate: base.addingTimeInterval(offset), pixelWidth: w, pixelHeight: h)
    }

    // MARK: - Time clustering

    func testCloseScreenshotsFormOneSession() {
        // Four shots ~3s apart → one session.
        let metas = [meta("a", 0), meta("b", 3), meta("c", 6), meta("d", 9)]
        let sessions = ScreenshotGrouping.group(metas)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].count, 4)
        XCTAssertEqual(sessions[0].items.map(\.id), ["a", "b", "c", "d"], "Items oldest→newest")
    }

    func testLargeTimeGapSplitsSessions() {
        // Two bursts separated by a 60s gap → two sessions.
        let metas = [meta("a", 0), meta("b", 3), meta("c", 63), meta("d", 66)]
        let sessions = ScreenshotGrouping.group(metas)
        XCTAssertEqual(sessions.count, 2)
        // Most-recent session first.
        XCTAssertEqual(sessions[0].items.map(\.id), ["c", "d"])
        XCTAssertEqual(sessions[1].items.map(\.id), ["a", "b"])
    }

    func testGapExactlyAtThresholdStaysTogether() {
        var config = ScreenshotGrouping.Config()
        config.maxGap = 10
        // Exactly 10s apart → still same session (<=).
        let metas = [meta("a", 0), meta("b", 10)]
        let sessions = ScreenshotGrouping.group(metas, config: config)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].count, 2)
    }

    // MARK: - Size splitting

    func testDifferentSizeSplitsSessions() {
        // Same time cadence, but the 3rd shot is a different size (e.g. rotated) → splits.
        let metas = [
            meta("a", 0, w: 1170, h: 2532),
            meta("b", 3, w: 1170, h: 2532),
            meta("c", 6, w: 2532, h: 1170), // landscape → different size
            meta("d", 9, w: 2532, h: 1170),
        ]
        let sessions = ScreenshotGrouping.group(metas)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(Set(sessions.map { $0.items.map(\.id) }), [["a", "b"], ["c", "d"]])
    }

    // MARK: - Min-size filtering

    func testLoneScreenshotIsDropped() {
        // A burst of 2, then a lone shot far away → only the burst survives.
        let metas = [meta("a", 0), meta("b", 3), meta("lonely", 600)]
        let sessions = ScreenshotGrouping.group(metas)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].items.map(\.id), ["a", "b"])
    }

    func testAllLoneShotsYieldNoSessions() {
        let metas = [meta("a", 0), meta("b", 100), meta("c", 200)]
        XCTAssertTrue(ScreenshotGrouping.group(metas).isEmpty, "No bursts → no sessions")
    }

    func testEmptyInput() {
        XCTAssertTrue(ScreenshotGrouping.group([]).isEmpty)
    }

    // MARK: - Unsorted input

    func testUnsortedInputIsHandled() {
        // Shuffled creation order → grouping must sort internally and still cluster correctly.
        let metas = [meta("d", 9), meta("a", 0), meta("c", 6), meta("b", 3)]
        let sessions = ScreenshotGrouping.group(metas)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].items.map(\.id), ["a", "b", "c", "d"], "Sorted oldest→newest")
    }
}
