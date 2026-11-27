// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreGraphics
import XCTest
@testable import PostShot

/// Validates header 3-way retention (`none` / `navBarOnly` / `full`), footer retention,
/// outlier-resilient first/last frame selection, and two-stage right-edge scrollbar removal.
final class HeaderFooterAndScrollbarTests: XCTestCase {

    // MARK: - Synthetic Frame Helpers

    private func makeGrayImage(width: Int, height: Int, pixels: [UInt8]) -> CGImage {
        var copy = pixels
        return copy.withUnsafeMutableBytes { ptr -> CGImage in
            let ctx = CGContext(
                data: ptr.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )!
            return ctx.makeImage()!
        }
    }

    private func grayPixels(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var out = [UInt8](repeating: 0, count: w * h)
        out.withUnsafeMutableBytes { ptr in
            let ctx = CGContext(
                data: ptr.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return out
    }

    private func rowMean(_ pixels: [UInt8], width: Int, y: Int, xRange: Range<Int>? = nil) -> Int {
        let cols = xRange ?? (0..<width)
        let sum = cols.reduce(0) { $0 + Int(pixels[y * width + $1]) }
        return sum / max(1, cols.count)
    }

    /// Generates deterministic scrolling body rows with intensities strictly in `145...225`
    /// so status (`40`), nav (`110`), and footer (`70`) bars are unambiguously distinguishable.
    private func makeBodyCanvas(width: Int, height: Int, seed: UInt64) -> [UInt8] {
        var px = [UInt8](repeating: 200, count: width * height)
        var state = seed &+ 0x9E3779B97F4A7C15
        for y in 0..<height {
            let rowTone = 148 + ((y * 19) % 36)
            for x in 0..<width {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let jitter = Int((state >> 58) & 0x1F)
                px[y * width + x] = UInt8(min(225, rowTone + jitter))
            }
        }
        return px
    }

    private func makeChromeFrame(
        width: Int = 160, height: Int = 360,
        bodySource: [UInt8], scrollY: Int,
        statusTone: UInt8 = 40, navTone: UInt8 = 110, footerTone: UInt8 = 70
    ) -> CGImage {
        var px = [UInt8](repeating: 0, count: width * height)
        for y in 0..<23 {
            for x in 0..<width { px[y * width + x] = statusTone }
        }
        for y in 23..<46 {
            for x in 0..<width { px[y * width + x] = navTone }
        }
        for y in 46..<324 {
            let srcY = scrollY + (y - 46)
            for x in 0..<width { px[y * width + x] = bodySource[srcY * width + x] }
        }
        for y in 324..<height {
            for x in 0..<width { px[y * width + x] = footerTone }
        }
        return makeGrayImage(width: width, height: height, pixels: px)
    }

    // MARK: - 1. Header 3-Way Mode & Footer Keep

    func testHeaderModesNoneNavBarOnlyAndFull() throws {
        let w = 160, h = 360
        let body = makeBodyCanvas(width: w, height: 900, seed: 101)
        let frames = [0, 120, 240].map { makeChromeFrame(width: w, height: h, bodySource: body, scrollY: $0) }
        let baseExpectedBodyH = 278 + 120 + 120 // 518

        var opts = StitchEngine.Options()
        opts.topCropFraction = 46.0 / 360.0
        opts.bottomCropFraction = 36.0 / 360.0

        // 1) .none + keepFooter == false
        opts.headerMode = .none
        opts.keepFooter = false
        let noneImg = try StitchEngine().stitchSync(images: frames, options: opts).get()
        let nonePx = grayPixels(noneImg)
        XCTAssertEqual(noneImg.height, baseExpectedBodyH, accuracy: 2)
        XCTAssertGreaterThan(rowMean(nonePx, width: w, y: 2), 140, "Top rows must be scrolling body")
        XCTAssertGreaterThan(rowMean(nonePx, width: w, y: noneImg.height - 3), 140, "Bottom rows must be body")

        // 2) .navBarOnly + keepFooter == false
        opts.headerMode = .navBarOnly
        let navImg = try StitchEngine().stitchSync(images: frames, options: opts).get()
        let navPx = grayPixels(navImg)
        XCTAssertEqual(navImg.height, baseExpectedBodyH + 23, accuracy: 2)
        for y in 0..<23 {
            XCTAssertEqual(rowMean(navPx, width: w, y: y), 110, accuracy: 2, "Nav bar row \(y) must be kept")
        }
        for y in 24..<(navImg.height - 2) {
            XCTAssertGreaterThan(rowMean(navPx, width: w, y: y), 140, "Middle seams must have no bars at row \(y)")
        }

        // 3) .full + keepFooter == true
        opts.headerMode = .full
        opts.keepFooter = true
        let fullImg = try StitchEngine().stitchSync(images: frames, options: opts).get()
        let fullPx = grayPixels(fullImg)
        XCTAssertEqual(fullImg.height, baseExpectedBodyH + 46 + 36, accuracy: 2)
        XCTAssertEqual(rowMean(fullPx, width: w, y: 10), 40, accuracy: 2, "Status bar must be preserved")
        XCTAssertEqual(rowMean(fullPx, width: w, y: 34), 110, accuracy: 2, "Nav bar must be preserved")
        XCTAssertEqual(rowMean(fullPx, width: w, y: fullImg.height - 15), 70, accuracy: 2, "Footer must be preserved")
        for y in 48..<(fullImg.height - 38) {
            XCTAssertGreaterThan(rowMean(fullPx, width: w, y: y), 140, "Interior seam row \(y) must exclude bars")
        }
    }

    // MARK: - 2. Leading & Trailing Outliers Skipped Without Leaking Outlier Chrome

    func testHeaderAndFooterWorkWhenLeadingAndTrailingOutliersAreSkipped() throws {
        let w = 160, h = 360
        let pageBody = makeBodyCanvas(width: w, height: 700, seed: 202)
        let outlierBodyA = makeBodyCanvas(width: w, height: 400, seed: 8081)
        let outlierBodyB = makeBodyCanvas(width: w, height: 400, seed: 9092)

        let outlier0 = makeChromeFrame(
            width: w, height: h, bodySource: outlierBodyA, scrollY: 0,
            statusTone: 15, navTone: 25, footerTone: 30
        )
        let page0 = makeChromeFrame(
            width: w, height: h, bodySource: pageBody, scrollY: 0,
            statusTone: 45, navTone: 95, footerTone: 55
        )
        let page1 = makeChromeFrame(
            width: w, height: h, bodySource: pageBody, scrollY: 120,
            statusTone: 45, navTone: 115, footerTone: 65
        )
        let outlierEnd = makeChromeFrame(
            width: w, height: h, bodySource: outlierBodyB, scrollY: 0,
            statusTone: 210, navTone: 220, footerTone: 235
        )

        var opts = StitchEngine.Options()
        opts.topCropFraction = 46.0 / 360.0
        opts.bottomCropFraction = 36.0 / 360.0
        opts.headerMode = .full
        opts.keepFooter = true

        let report = try StitchEngine().stitchWithReportSync(
            images: [outlier0, page0, page1, outlierEnd], options: opts
        ).get()
        XCTAssertEqual(report.skippedIndices, [0, 3])

        let px = grayPixels(report.image)
        XCTAssertEqual(rowMean(px, width: w, y: 10), 45, accuracy: 2, "Must use page0 status bar, not outlier0")
        XCTAssertEqual(rowMean(px, width: w, y: 34), 95, accuracy: 2, "Must use page0 nav bar, not outlier0")
        XCTAssertEqual(rowMean(px, width: w, y: report.image.height - 15), 65, accuracy: 2,
                       "Must use page1 footer, not outlierEnd")
    }

    // MARK: - 3. Stage 1 Cross-Frame Authentic Scrollbar Replacement in Overlap

    func testOverlapScrollbarRemovedByCrossFrameAuthenticPixels() throws {
        let w = 120, h = 300, overlap = 180
        // Build scrolling page content (height 420) over #EDEDED (237), including full-width
        // horizontal divider bands reaching x: 0..<120 so authentic pixel restoration is tested.
        var page = [UInt8](repeating: 237, count: w * 420)
        var rng: UInt64 = 0x55AA1234FEDC9876
        for y in 0..<420 {
            if y % 34 == 16 {
                for x in 0..<w { page[y * w + x] = 196 }
            } else if y % 11 < 5 {
                rng = rng &* 6364136223846793005 &+ 1442695040888963407
                let textEnd = 45 + Int((rng >> 56) % 50)
                for x in 10..<textEnd where (x + y) % 3 != 0 { page[y * w + x] = 48 }
            }
        }

        let advance = h - overlap
        var f0 = Array(page[0..<(w * h)])
        var f1 = Array(page[(advance * w)..<((advance + h) * w)])
        // Frame 0 scrollbar pill at x: 112..<117, y: 150..<230 (inside overlap 120..<300!).
        for y in 150..<230 {
            for x in 112..<117 { f0[y * w + x] = 75 }
        }
        // Frame 1 scrollbar pill shifted down to y: 190..<270 (outside Frame 1's 0..<180 overlap!).
        for y in 190..<270 {
            for x in 112..<117 { f1[y * w + x] = 75 }
        }

        let img0 = makeGrayImage(width: w, height: h, pixels: f0)
        let img1 = makeGrayImage(width: w, height: h, pixels: f1)

        var optsOff = StitchEngine.Options()
        optsOff.removeScrollIndicator = false
        let keptOut = try StitchEngine().stitchSync(images: [img0, img1], options: optsOff).get()
        let keptPx = grayPixels(keptOut)
        let remainingWhenOff = countDarkPixels(keptPx, width: w, xRange: 112..<117, yRange: 120..<300, threshold: 120)
        XCTAssertGreaterThanOrEqual(remainingWhenOff, 250, "Scrollbar must remain visible when removal is disabled")

        var optsOn = StitchEngine.Options()
        optsOn.removeScrollIndicator = true
        let cleanOut = try StitchEngine().stitchSync(images: [img0, img1], options: optsOn).get()
        let cleanPx = grayPixels(cleanOut)
        let remainingWhenOn = countDarkPixels(cleanPx, width: w, xRange: 112..<117, yRange: 120..<300, threshold: 120)
        XCTAssertEqual(remainingWhenOn, 0, "Overlap region must have ZERO scrollbar pixels when removal is enabled")
        // Authentic full-width divider at y = 186 inside the pill span must also be restored intact!
        XCTAssertEqual(Int(cleanPx[186 * w + 114]), 196, accuracy: 2, "Authentic divider pixel must be restored")
    }

    // MARK: - 4. Stage 2 Non-Overlapped Margin Cleanup vs Textured Edge Preservation

    func testNonOverlappedMarginScrollbarCleanedWhileTexturedEdgePreserved() throws {
        let w = 120, h = 300
        var page = [UInt8](repeating: 237, count: w * 440)
        var rng: UInt64 = 0xCAFEBABE13572468
        for y in 0..<440 where y % 10 < 4 {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            let endX = 42 + Int((rng >> 56) % 48)
            for x in 12..<endX where (x + y * 2) % 3 != 0 { page[y * w + x] = 45 }
        }
        // High-contrast textured edge-bleed photo reaching the right edge in non-overlapped rows 85..<130.
        for y in 85..<130 {
            for x in 90..<w {
                page[y * w + x] = ((x / 2 + y / 2) % 2 == 0) ? 45 : 225
            }
        }

        var f0 = Array(page[0..<(w * h)])
        let f1 = Array(page[(140 * w)..<(440 * w)]) // 160px overlap (140..<300)
        // Non-overlapped scrollbar pill at top of Frame 0 (y: 18..<74) over flat #EDEDED (237) margin.
        for y in 18..<74 {
            for x in 112..<117 { f0[y * w + x] = 110 }
        }

        let out = try StitchEngine().stitchSync(
            images: [makeGrayImage(width: w, height: h, pixels: f0), makeGrayImage(width: w, height: h, pixels: f1)]
        ).get()
        let outPx = grayPixels(out)

        let pillLeftovers = countDarkPixels(outPx, width: w, xRange: 112..<117, yRange: 18..<74, threshold: 200)
        XCTAssertEqual(pillLeftovers, 0, "Non-overlapped pill over uniform #EDEDED margin must be cleaned")

        for y in 85..<130 {
            for x in 110..<w {
                let expected = Int(page[y * w + x])
                let actual = Int(outPx[y * w + x])
                XCTAssertEqual(actual, expected, accuracy: 2, "Textured right-edge pixel (\(x),\(y)) must not smear")
            }
        }
    }

    func testRightAlignedChatAvatarNeverInjectsOrLeavesTruncatedScrollbar() throws {
        // Mirrors real 1320px iPhone Pro Max geometry scaled 1:4 -> 330px wide:
        // right-side avatar at x: 292..<321 (right margin 9px = 2.7%), scrollbar at x: 325..<328 (inset 2px).
        let w = 330, h = 280
        var page = [UInt8](repeating: 237, count: w * 460)
        for y in 0..<460 where y % 14 < 5 {
            for x in 20..<180 { page[y * w + x] = 55 }
        }
        // Right-side dark & mid-gray chat avatars at y: 90..<140 and y: 230..<280 (ending at x = 321).
        for avatarStart in [90, 230] {
            for y in avatarStart..<(avatarStart + 50) {
                for x in 292..<321 {
                    page[y * w + x] = ((x + y) % 5 == 0) ? 175 : 55
                }
            }
        }

        let adv = 90, ov = h - adv // 190px overlap (high overlap!)
        var f0 = Array(page[0..<(w * h)])
        var f1 = Array(page[(adv * w)..<((adv + h) * w)])
        var f2 = Array(page[(2 * adv * w)..<((2 * adv + h) * w)])
        // Tall 130px scrollbars that overlap each other across consecutive frames AND pass right
        // next to the right-aligned avatars, plus a tail scrollbar at the bottom of f2!
        for y in 110..<240 { for x in 325..<328 { f0[y * w + x] = 148 } }
        for y in 130..<260 { for x in 325..<328 { f1[y * w + x] = 148 } }
        for y in 145..<275 { for x in 325..<328 { f2[y * w + x] = 148 } }

        let segs = [
            ImageCompositor.Segment(image: makeGrayImage(width: w, height: h, pixels: f0), overlap: 0),
            ImageCompositor.Segment(image: makeGrayImage(width: w, height: h, pixels: f1), overlap: ov - 1),
            ImageCompositor.Segment(image: makeGrayImage(width: w, height: h, pixels: f2), overlap: ov),
        ]
        let cleanImg = try ImageCompositor.composite(segments: segs, width: w, removeScrollIndicator: true)
        let cleanPx = grayPixels(cleanImg)
        let leftover = countDarkPixels(cleanPx, width: w, xRange: 322..<w, yRange: 0..<cleanImg.height, threshold: 215)
        XCTAssertEqual(leftover, 0, "Zero truncated middle or bottom scrollbar pixels may remain next to avatars")
    }

    private func countDarkPixels(
        _ pixels: [UInt8], width: Int, xRange: Range<Int>, yRange: Range<Int>, threshold: UInt8
    ) -> Int {
        var count = 0
        for y in yRange {
            for x in xRange where pixels[y * width + x] < threshold {
                count += 1
            }
        }
        return count
    }
}
