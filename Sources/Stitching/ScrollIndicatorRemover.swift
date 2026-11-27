// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreGraphics
import Foundation

/// Removes right-edge vertical iOS scroll indicators using a two-stage algorithm:
/// 1. Authentic cross-frame pixel replacement inside overlap zones.
/// 2. Conservative uniform-margin pill cleanup in non-overlapped body rows.
enum ScrollIndicatorRemover {

    private struct Zone {
        let width: Int
        let stripWidth: Int
        let refWidth: Int
        var stripStartX: Int { width - stripWidth }
        var refStartX: Int { width - stripWidth - refWidth }
        var bandWidth: Int { refWidth + stripWidth }
    }

    private struct RowRefStats {
        var uniform: Bool = false
        var meanR: Float = 0
        var meanG: Float = 0
        var meanB: Float = 0
        var meanLuma: Float = 0
        var maxStripDiff: Float = 0
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
        let rawStrip = Int((Float(width) * 0.024).rounded(.up))
        let stripWidth = min(36, min(width / 5, max(10, rawStrip)))
        let refWidth = max(4, min(24, stripWidth))
        guard stripWidth + refWidth <= width else { return }
        let zone = Zone(width: width, stripWidth: stripWidth, refWidth: refWidth)
        let canvas = rawData.assumingMemoryBound(to: UInt8.self)
        let stride = context.bytesPerRow

        let cleanedRows = cleanOverlapSeams(
            canvas: canvas, stride: stride, zone: zone,
            segments: segments, scaledHeights: scaledHeights,
            overlaps: overlaps, totalHeight: totalHeight, colorSpace: colorSpace
        )

        let safeTop = max(0, min(protectedTopRows, totalHeight))
        let safeBottom = max(0, min(protectedBottomRows, totalHeight - safeTop))
        cleanNonOverlappedMargins(
            canvas: canvas, stride: stride, zone: zone,
            bodyRange: safeTop..<(totalHeight - safeBottom),
            cleanedRows: cleanedRows
        )
    }

    // MARK: - Stage 1: Cross-Frame Authentic Pixel Replacement

    private static func cleanOverlapSeams(
        canvas: UnsafeMutablePointer<UInt8>, stride: Int, zone: Zone,
        segments: [ImageCompositor.Segment], scaledHeights: [Int],
        overlaps: [Int], totalHeight: Int, colorSpace: CGColorSpace
    ) -> [Bool] {
        var cleaned = [Bool](repeating: false, count: totalHeight)
        guard segments.count >= 2 else { return cleaned }
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
                seamStartY: segTopY, overlap: ov, totalHeight: totalHeight,
                cleaned: &cleaned
            )
        }
        return cleaned
    }

    private static func applySeamReplacement(
        canvas: UnsafeMutablePointer<UInt8>, stride: Int, zone: Zone,
        patchA: [UInt8], patchB: [UInt8],
        seamStartY: Int, overlap: Int, totalHeight: Int,
        cleaned: inout [Bool]
    ) {
        let anomA = boxSmooth5(patchRowAnomalies(patch: patchA, zone: zone, rows: overlap))
        let anomB = boxSmooth5(patchRowAnomalies(patch: patchB, zone: zone, rows: overlap))
        let patchStride = zone.bandWidth * 4
        for r in 0..<overlap {
            let canvasY = seamStartY + r
            guard canvasY >= 0, canvasY < totalHeight else { continue }
            guard abs(anomA[r] - anomB[r]) >= 6.0 else { continue }
            let src = anomA[r] <= anomB[r] ? patchA : patchB
            writeStripRow(
                canvas: canvas, canvasStride: stride, canvasY: canvasY,
                srcPatch: src, srcRowOffset: r * patchStride, zone: zone
            )
            cleaned[canvasY] = true
        }
    }

    private static func writeStripRow(
        canvas: UnsafeMutablePointer<UInt8>, canvasStride: Int, canvasY: Int,
        srcPatch: [UInt8], srcRowOffset: Int, zone: Zone
    ) {
        let dstRow = canvasY * canvasStride
        for s in 0..<zone.stripWidth {
            let srcIdx = srcRowOffset + (zone.refWidth + s) * 4
            let dstIdx = dstRow + (zone.stripStartX + s) * 4
            let sR = Float(srcPatch[srcIdx]), sG = Float(srcPatch[srcIdx + 1]), sB = Float(srcPatch[srcIdx + 2])
            let dR = Float(canvas[dstIdx]), dG = Float(canvas[dstIdx + 1]), dB = Float(canvas[dstIdx + 2])
            let diff = max(abs(sR - dR), max(abs(sG - dG), abs(sB - dB)))
            let weight: Float = (zone.stripWidth >= 6 && s < 2 && diff <= 16.0)
                ? (s == 0 ? 0.35 : 0.70) : 1.0
            canvas[dstIdx] = UInt8(clamping: Int((dR + (sR - dR) * weight).rounded()))
            canvas[dstIdx + 1] = UInt8(clamping: Int((dG + (sG - dG) * weight).rounded()))
            canvas[dstIdx + 2] = UInt8(clamping: Int((dB + (sB - dB) * weight).rounded()))
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

    private static func patchRowAnomalies(patch: [UInt8], zone: Zone, rows: Int) -> [Float] {
        var out = [Float](repeating: 0, count: rows)
        let rowStride = zone.bandWidth * 4
        let invRef = 1.0 / Float(max(1, zone.refWidth))
        for r in 0..<rows {
            let base = r * rowStride
            var sumR: Float = 0, sumG: Float = 0, sumB: Float = 0
            for x in 0..<zone.refWidth {
                let p = base + x * 4
                sumR += Float(patch[p]); sumG += Float(patch[p + 1]); sumB += Float(patch[p + 2])
            }
            let mR = sumR * invRef, mG = sumG * invRef, mB = sumB * invRef
            let mLuma = luma(mR, mG, mB)
            var peak: Float = 0
            for s in 0..<zone.stripWidth {
                let p = base + (zone.refWidth + s) * 4
                peak = max(peak, pixelDiff(patch[p], patch[p + 1], patch[p + 2], mR, mG, mB, mLuma))
            }
            out[r] = peak
        }
        return out
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

    // MARK: - Stage 2: Conservative Non-Overlapped Margin Pill Cleanup

    private static func cleanNonOverlappedMargins(
        canvas: UnsafeMutablePointer<UInt8>, stride: Int, zone: Zone,
        bodyRange: Range<Int>, cleanedRows: [Bool]
    ) {
        guard bodyRange.count >= 12 else { return }
        let maxRunLen = max(24, Int(Float(bodyRange.count) * 0.85))
        var stats = [RowRefStats](repeating: RowRefStats(), count: bodyRange.upperBound)
        for y in bodyRange where !cleanedRows[y] {
            stats[y] = measureCanvasRow(canvas: canvas, stride: stride, y: y, zone: zone)
        }

        var y = bodyRange.lowerBound
        while y < bodyRange.upperBound {
            guard isPillCandidate(stats[y], cleaned: cleanedRows[y]) else { y += 1; continue }
            var end = y + 1
            var minMean = stats[y].meanLuma, maxMean = stats[y].meanLuma
            while end < bodyRange.upperBound,
                  isPillCandidate(stats[end], cleaned: cleanedRows[end]),
                  abs(stats[end].meanLuma - stats[end - 1].meanLuma) <= 6.0,
                  max(maxMean, stats[end].meanLuma) - min(minMean, stats[end].meanLuma) <= 16.0 {
                minMean = min(minMean, stats[end].meanLuma)
                maxMean = max(maxMean, stats[end].meanLuma)
                end += 1
            }
            let run = y..<end
            if run.count >= 12, run.count <= maxRunLen,
               hasConsistentPillColumn(canvas: canvas, stride: stride, run: run, stats: stats, zone: zone) {
                fillVerifiedPillRun(canvas: canvas, stride: stride, run: run, stats: stats, zone: zone)
            }
            y = end
        }
    }

    private static func isPillCandidate(_ row: RowRefStats, cleaned: Bool) -> Bool {
        !cleaned && row.uniform && row.maxStripDiff >= 12.0 && row.maxStripDiff <= 215.0
    }

    private static func measureCanvasRow(
        canvas: UnsafeMutablePointer<UInt8>, stride: Int, y: Int, zone: Zone
    ) -> RowRefStats {
        let rowBase = y * stride
        var minL: Float = 255, maxL: Float = 0
        var sumR: Float = 0, sumG: Float = 0, sumB: Float = 0
        for x in zone.refStartX..<zone.stripStartX {
            let p = rowBase + x * 4
            let r = Float(canvas[p]), g = Float(canvas[p + 1]), b = Float(canvas[p + 2])
            let l = luma(r, g, b)
            minL = min(minL, l); maxL = max(maxL, l)
            sumR += r; sumG += g; sumB += b
        }
        guard (maxL - minL) <= 8.0 else { return RowRefStats(uniform: false) }
        let inv = 1.0 / Float(zone.refWidth)
        let mR = sumR * inv, mG = sumG * inv, mB = sumB * inv
        let mLuma = luma(mR, mG, mB)
        var maxDiff: Float = 0
        for x in zone.stripStartX..<zone.width {
            let p = rowBase + x * 4
            maxDiff = max(maxDiff, pixelDiff(canvas[p], canvas[p + 1], canvas[p + 2], mR, mG, mB, mLuma))
        }
        return RowRefStats(uniform: true, meanR: mR, meanG: mG, meanB: mB, meanLuma: mLuma, maxStripDiff: maxDiff)
    }

    private static func hasConsistentPillColumn(
        canvas: UnsafeMutablePointer<UInt8>, stride: Int,
        run: Range<Int>, stats: [RowRefStats], zone: Zone
    ) -> Bool {
        let trim = run.count >= 16 ? 2 : 0
        let core = (run.lowerBound + trim)..<(run.upperBound - trim)
        let needed = max(1, Int((Float(core.count) * 0.8).rounded(.up)))
        for s in 0..<zone.stripWidth {
            var hits = 0
            let x = zone.stripStartX + s
            for y in core {
                let p = y * stride + x * 4
                let st = stats[y]
                if pixelDiff(canvas[p], canvas[p + 1], canvas[p + 2], st.meanR, st.meanG, st.meanB, st.meanLuma) >= 12.0 {
                    hits += 1
                }
            }
            if hits >= needed { return true }
        }
        return false
    }

    private static func fillVerifiedPillRun(
        canvas: UnsafeMutablePointer<UInt8>, stride: Int,
        run: Range<Int>, stats: [RowRefStats], zone: Zone
    ) {
        for y in run {
            let st = stats[y]
            let rByte = UInt8(clamping: Int(st.meanR.rounded()))
            let gByte = UInt8(clamping: Int(st.meanG.rounded()))
            let bByte = UInt8(clamping: Int(st.meanB.rounded()))
            let rowBase = y * stride
            for x in zone.stripStartX..<zone.width {
                let p = rowBase + x * 4
                if pixelDiff(canvas[p], canvas[p + 1], canvas[p + 2], st.meanR, st.meanG, st.meanB, st.meanLuma) >= 10.0 {
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
