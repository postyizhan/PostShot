// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreGraphics
import Foundation

/// Removes right-edge vertical iOS scroll indicators using dual-flank capsule detection:
/// an iOS scrollbar pill is strictly inset from the right screen edge (`2–9px` outer margin) and
/// separated from right-aligned content/avatars (`>= 30px` from screen edge on 3× displays).
/// Measuring `min(diffFromInnerFlank, diffFromOuterEdge)` isolates true inset scrollbar capsules
/// and can never be fooled by right-aligned chat avatars, bubbles, or full-width dividers.
enum ScrollIndicatorRemover {

    private struct Zone {
        let width: Int
        let refWidth: Int
        let trackWidth: Int
        let outerWidth: Int
        var outerStartX: Int { width - outerWidth }
        var trackStartX: Int { width - outerWidth - trackWidth }
        var refStartX: Int { width - outerWidth - trackWidth - refWidth }
        var stripStartX: Int { trackStartX }
        var stripWidth: Int { trackWidth + outerWidth }
        var bandWidth: Int { refWidth + trackWidth + outerWidth }
    }

    private struct FlankStats {
        var valid: Bool = false
        var meanR: Float = 0
        var meanG: Float = 0
        var meanB: Float = 0
        var meanLuma: Float = 0
        var pillPeak: Float = 0
    }

    static func clean(
        context: CGContext,
        segments: [ImageCompositor.Segment],
        scaledHeights: [Int],
        overlaps: [Int],
        totalHeight: Int,
        colorSpace: CGColorSpace,
        protectedTopRows: Int,
        protectedBottomRows: Int
    ) {
        let width = context.width
        guard width >= 48, totalHeight > 0, let rawData = context.data else { return }
        guard let zone = makeZone(width: width) else { return }
        let canvas = rawData.assumingMemoryBound(to: UInt8.self)
        let stride = context.bytesPerRow

        cleanOverlapSeams(
            canvas: canvas, stride: stride, zone: zone,
            segments: segments, scaledHeights: scaledHeights,
            overlaps: overlaps, totalHeight: totalHeight, colorSpace: colorSpace
        )

        let safeTop = max(0, min(protectedTopRows, totalHeight))
        let safeBottom = max(0, min(protectedBottomRows, totalHeight - safeTop))
        cleanRemainingCapsules(
            canvas: canvas, stride: stride, zone: zone,
            bodyRange: safeTop..<(totalHeight - safeBottom)
        )
    }

    /// Builds a narrow right-margin geometry strictly outside right-aligned UI content (`<= 2.4%`
    /// of width on full-res iPhone screens, i.e. rightmost ~31px on 1320px, clear of `x <= 1284` avatars).
    private static func makeZone(width: Int) -> Zone? {
        let outerWidth = max(2, min(5, Int((Float(width) * 0.0038).rounded(.up))))
        let trackWidth = max(6, min(18, Int((Float(width) * 0.0135).rounded(.up))))
        let refWidth = max(4, min(9, Int((Float(width) * 0.0068).rounded(.up))))
        guard outerWidth + trackWidth + refWidth <= width else { return nil }
        return Zone(width: width, refWidth: refWidth, trackWidth: trackWidth, outerWidth: outerWidth)
    }

    // MARK: - Stage 1: Cross-Frame Authentic Pixel Replacement

    private static func cleanOverlapSeams(
        canvas: UnsafeMutablePointer<UInt8>, stride: Int, zone: Zone,
        segments: [ImageCompositor.Segment], scaledHeights: [Int],
        overlaps: [Int], totalHeight: Int, colorSpace: CGColorSpace
    ) {
        guard segments.count >= 2 else { return }
        var segTopY = 0
        for i in 1..<segments.count {
            let hPrev = scaledHeights[i - 1], hCurr = scaledHeights[i]
            let ov = overlaps[i]
            segTopY += (hPrev - ov)
            guard ov > 0, hPrev >= ov, hCurr >= ov else { continue }
            guard let patchA = extractBand(
                image: segments[i - 1].image, fullWidth: zone.width, fullHeight: hPrev,
                xStart: zone.refStartX, bandWidth: zone.bandWidth,
                yStart: hPrev - ov, rowCount: ov, colorSpace: colorSpace
            ), let patchB = extractBand(
                image: segments[i].image, fullWidth: zone.width, fullHeight: hCurr,
                xStart: zone.refStartX, bandWidth: zone.bandWidth,
                yStart: 0, rowCount: ov, colorSpace: colorSpace
            ) else { continue }

            applySeamReplacement(
                canvas: canvas, stride: stride, zone: zone,
                patchA: patchA, patchB: patchB,
                seamStartY: segTopY, overlap: ov, totalHeight: totalHeight
            )
        }
    }

    private static func applySeamReplacement(
        canvas: UnsafeMutablePointer<UInt8>, stride: Int, zone: Zone,
        patchA: [UInt8], patchB: [UInt8],
        seamStartY: Int, overlap: Int, totalHeight: Int
    ) {
        let pillA = boxSmooth5(patchDualFlankScores(patch: patchA, zone: zone, rows: overlap))
        let pillB = boxSmooth5(patchDualFlankScores(patch: patchB, zone: zone, rows: overlap))
        let patchStride = zone.bandWidth * 4
        for r in 0..<overlap {
            let canvasY = seamStartY + r
            guard canvasY >= 0, canvasY < totalHeight else { continue }
            let canvasScore = canvasDualFlankScore(canvas: canvas, stride: stride, y: canvasY, zone: zone)
            let bestIsA = pillA[r] <= pillB[r]
            let bestScore = bestIsA ? pillA[r] : pillB[r]
            // Never overwrite the canvas unless the candidate frame has strictly lower capsule
            // anomaly than what is ALREADY drawn on the canvas!
            guard canvasScore >= 8.0, canvasScore - bestScore >= 6.0 else { continue }
            let src = bestIsA ? patchA : patchB
            writeTrackRow(
                canvas: canvas, canvasStride: stride, canvasY: canvasY,
                srcPatch: src, srcRowOffset: r * patchStride, zone: zone
            )
        }
    }

    private static func writeTrackRow(
        canvas: UnsafeMutablePointer<UInt8>, canvasStride: Int, canvasY: Int,
        srcPatch: [UInt8], srcRowOffset: Int, zone: Zone
    ) {
        let dstRow = canvasY * canvasStride
        for s in 0..<zone.stripWidth {
            let srcIdx = srcRowOffset + (zone.refWidth + s) * 4
            let dstIdx = dstRow + (zone.stripStartX + s) * 4
            canvas[dstIdx] = srcPatch[srcIdx]
            canvas[dstIdx + 1] = srcPatch[srcIdx + 1]
            canvas[dstIdx + 2] = srcPatch[srcIdx + 2]
            canvas[dstIdx + 3] = 255
        }
    }

    private static func extractBand(
        image: CGImage, fullWidth: Int, fullHeight: Int,
        xStart: Int, bandWidth: Int, yStart: Int, rowCount: Int, colorSpace: CGColorSpace
    ) -> [UInt8]? {
        guard bandWidth > 0, rowCount > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: bandWidth * rowCount * 4)
        let ok = buf.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(
                data: ptr.baseAddress, width: bandWidth, height: rowCount,
                bitsPerComponent: 8, bytesPerRow: bandWidth * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            if image.width == fullWidth, image.height == fullHeight,
               let sub = image.cropping(to: CGRect(x: xStart, y: yStart, width: bandWidth, height: rowCount)) {
                ctx.interpolationQuality = .none
                ctx.draw(sub, in: CGRect(x: 0, y: 0, width: bandWidth, height: rowCount))
            } else {
                ctx.interpolationQuality = .high
                let drawY = (yStart + rowCount) - fullHeight
                ctx.draw(image, in: CGRect(x: -xStart, y: drawY, width: fullWidth, height: fullHeight))
            }
            return true
        }
        return ok ? buf : nil
    }

    /// Dual-flank capsule score `min(diffFromInnerRef, diffFromOuterEdge)`: non-zero ONLY when a
    /// narrow vertical bar sits sandwiched between matching inner and outer margin flanks.
    private static func patchDualFlankScores(patch: [UInt8], zone: Zone, rows: Int) -> [Float] {
        var out = [Float](repeating: 0, count: rows)
        let rowStride = zone.bandWidth * 4
        for r in 0..<rows {
            out[r] = rowDualFlankScore(rowPtr: patch, base: r * rowStride, zone: zone)
        }
        return out
    }

    private static func canvasDualFlankScore(
        canvas: UnsafeMutablePointer<UInt8>, stride: Int, y: Int, zone: Zone
    ) -> Float {
        let base = y * stride + zone.refStartX * 4
        let count = zone.bandWidth * 4
        let slice = Array(UnsafeBufferPointer(start: canvas.advanced(by: base), count: count))
        return rowDualFlankScore(rowPtr: slice, base: 0, zone: zone)
    }

    private static func rowDualFlankScore(rowPtr: [UInt8], base: Int, zone: Zone) -> Float {
        let left = meanRGB(rowPtr, base: base, startCol: 0, count: zone.refWidth)
        let outerStart = zone.refWidth + zone.trackWidth
        let right = meanRGB(rowPtr, base: base, startCol: outerStart, count: zone.outerWidth)
        let leftL = luma(left.r, left.g, left.b)
        let rightL = luma(right.r, right.g, right.b)
        var peak: Float = 0
        for s in 0..<zone.trackWidth {
            let p = base + (zone.refWidth + s) * 4
            let dL = pixelDiff(rowPtr[p], rowPtr[p + 1], rowPtr[p + 2], left.r, left.g, left.b, leftL)
            let dR = pixelDiff(rowPtr[p], rowPtr[p + 1], rowPtr[p + 2], right.r, right.g, right.b, rightL)
            peak = max(peak, min(dL, dR))
        }
        return peak
    }

    private static func meanRGB(
        _ buf: [UInt8], base: Int, startCol: Int, count: Int
    ) -> (r: Float, g: Float, b: Float) {
        let inv = 1.0 / Float(max(1, count))
        var sr: Float = 0, sg: Float = 0, sb: Float = 0
        for i in 0..<count {
            let p = base + (startCol + i) * 4
            sr += Float(buf[p]); sg += Float(buf[p + 1]); sb += Float(buf[p + 2])
        }
        return (sr * inv, sg * inv, sb * inv)
    }

    private static func boxSmooth5(_ values: [Float]) -> [Float] {
        let n = values.count
        guard n > 1 else { return values }
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let lo = max(0, i - 2), hi = min(n - 1, i + 2)
            var sum: Float = 0
            for j in lo...hi { sum += values[j] }
            out[i] = sum / Float(hi - lo + 1)
        }
        return out
    }

    // MARK: - Stage 2: Clean Any Remaining Sandwiched Capsules (Tail & Overlapping Bars)

    private static func cleanRemainingCapsules(
        canvas: UnsafeMutablePointer<UInt8>, stride: Int, zone: Zone, bodyRange: Range<Int>
    ) {
        guard bodyRange.count >= 10 else { return }
        var stats = [FlankStats](repeating: FlankStats(), count: bodyRange.upperBound)
        for y in bodyRange {
            stats[y] = measureFlanks(canvas: canvas, stride: stride, y: y, zone: zone)
        }

        var y = bodyRange.lowerBound
        while y < bodyRange.upperBound {
            guard stats[y].valid, stats[y].pillPeak >= 10.0 else { y += 1; continue }
            var end = y + 1
            while end < bodyRange.upperBound,
                  stats[end].valid, stats[end].pillPeak >= 10.0,
                  abs(stats[end].meanLuma - stats[end - 1].meanLuma) <= 8.0 {
                end += 1
            }
            let run = y..<end
            if run.count >= 10,
               hasConsistentCapsuleColumn(canvas: canvas, stride: stride, run: run, stats: stats, zone: zone) {
                fillCapsuleRun(canvas: canvas, stride: stride, run: run, stats: stats, zone: zone)
            }
            y = end
        }
    }

    private static func measureFlanks(
        canvas: UnsafeMutablePointer<UInt8>, stride: Int, y: Int, zone: Zone
    ) -> FlankStats {
        let rowBase = y * stride
        var minL: Float = 255, maxL: Float = 0
        var sr: Float = 0, sg: Float = 0, sb: Float = 0
        let flankCols = Array(zone.refStartX..<zone.trackStartX) + Array(zone.outerStartX..<zone.width)
        for x in flankCols {
            let p = rowBase + x * 4
            let r = Float(canvas[p]), g = Float(canvas[p + 1]), b = Float(canvas[p + 2])
            let l = luma(r, g, b)
            minL = min(minL, l); maxL = max(maxL, l)
            sr += r; sg += g; sb += b
        }
        guard (maxL - minL) <= 10.0 else { return FlankStats(valid: false) }
        let inv = 1.0 / Float(max(1, flankCols.count))
        let mR = sr * inv, mG = sg * inv, mB = sb * inv
        let mLuma = luma(mR, mG, mB)
        var peak: Float = 0
        for x in zone.trackStartX..<zone.outerStartX {
            let p = rowBase + x * 4
            peak = max(peak, pixelDiff(canvas[p], canvas[p + 1], canvas[p + 2], mR, mG, mB, mLuma))
        }
        return FlankStats(valid: true, meanR: mR, meanG: mG, meanB: mB, meanLuma: mLuma, pillPeak: peak)
    }

    private static func hasConsistentCapsuleColumn(
        canvas: UnsafeMutablePointer<UInt8>, stride: Int,
        run: Range<Int>, stats: [FlankStats], zone: Zone
    ) -> Bool {
        let trim = run.count >= 14 ? 2 : 0
        let core = (run.lowerBound + trim)..<(run.upperBound - trim)
        let needed = max(1, Int((Float(core.count) * 0.75).rounded(.up)))
        for x in zone.trackStartX..<zone.outerStartX {
            var hits = 0
            for y in core {
                let p = y * stride + x * 4
                let st = stats[y]
                if pixelDiff(canvas[p], canvas[p + 1], canvas[p + 2], st.meanR, st.meanG, st.meanB, st.meanLuma) >= 10.0 {
                    hits += 1
                }
            }
            if hits >= needed { return true }
        }
        return false
    }

    private static func fillCapsuleRun(
        canvas: UnsafeMutablePointer<UInt8>, stride: Int,
        run: Range<Int>, stats: [FlankStats], zone: Zone
    ) {
        for y in run {
            let st = stats[y]
            let rByte = UInt8(clamping: Int(st.meanR.rounded()))
            let gByte = UInt8(clamping: Int(st.meanG.rounded()))
            let bByte = UInt8(clamping: Int(st.meanB.rounded()))
            let rowBase = y * stride
            for x in zone.trackStartX..<zone.outerStartX {
                let p = rowBase + x * 4
                if pixelDiff(canvas[p], canvas[p + 1], canvas[p + 2], st.meanR, st.meanG, st.meanB, st.meanLuma) >= 8.0 {
                    canvas[p] = rByte
                    canvas[p + 1] = gByte
                    canvas[p + 2] = bByte
                    canvas[p + 3] = 255
                }
            }
        }
    }

    private static func luma(_ r: Float, _ g: Float, _ b: Float) -> Float {
        0.299 * r + 0.587 * g + 0.114 * b
    }

    private static func pixelDiff(
        _ r: UInt8, _ g: UInt8, _ b: UInt8,
        _ mR: Float, _ mG: Float, _ mB: Float, _ mLuma: Float
    ) -> Float {
        let rf = Float(r), gf = Float(g), bf = Float(b)
        let cDiff = max(abs(rf - mR), max(abs(gf - mG), abs(bf - mB)))
        return max(abs(luma(rf, gf, bf) - mLuma), cDiff)
    }
}
