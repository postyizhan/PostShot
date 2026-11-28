// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

extension StitchViewModel {
    func formatNotice(report: StitchReport) -> String? {
        var parts: [String] = []
        switch report.orderAdjustment {
        case .none:
            break
        case .reversed:
            parts.append("已自动识别反向滚动并调整顺序")
        case .reordered:
            parts.append("已自动恢复截图顺序")
        }
        if report.backtrackSkippedCount > 0 && report.skippedIndices.count == report.backtrackSkippedCount {
            parts.append("已自动跳过 \(report.backtrackSkippedCount) 帧轻微回拉画面")
        } else if !report.skippedIndices.isEmpty {
            let labels = report.skippedIndices.map { String($0 + 1) }.joined(separator: "、")
            parts.append("已自动跳过第 \(labels) 张不衔接画面")
        }
        if report.backfilledCount > 0 {
            parts.append("从录制帧池自动补齐 \(report.backfilledCount) 帧")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "，")
    }

    func failedLoadMessage(prefix: String, indices: [Int]) -> String {
        let labels = indices.map { String($0 + 1) }.joined(separator: "、")
        return "第 \(labels) 张\(prefix)解码失败。为避免改变相邻关系，已取消本次加载。"
    }

    func describe(_ error: StitchEngine.StitchError) -> String {
        switch error {
        case .noImages:
            return "请至少选择 2 张图片。"
        case .invalidInput(let profile):
            if let first = profile.diagnostics.first {
                let idx = first.sourceIndex + 1
                switch first.reason {
                case .empty, .nonPositiveDimensions, .impossiblePixelCount:
                    return "第\(idx)张图片尺寸无效（或裁剪比例过大），无法拼接。"
                case .dimensionMismatch:
                    return "第\(idx)张图片尺寸与首张不一致（\(first.actual) vs \(profile.canonicalSize)），无法安全拼接。"
                }
            }
            return "输入图片校验未通过，无法拼接。"
        case .unsafeSeam(let seam):
            let a = seam.topIndex + 1, b = seam.bottomIndex + 1
            if seam.isReverseConflict {
                return "第\(a)张与第\(b)张检测到反向滚动或中途大幅折返；请保持单向滚动，或尝试倒序/删减异常帧后重试。"
            } else if seam.result.status == .ambiguous {
                return "第\(a)张与第\(b)张存在多处相似内容，自动匹配不确定；可删除异常帧或调整裁剪后重试。"
            } else {
                return "第\(a)张与第\(b)张未找到可靠重叠区域；可能滚动跨度过大、顺序颠倒或混入无关画面。"
            }
        case .compositeFailed(let underlying):
            return "合成图像失败：\(underlying.localizedDescription)"
        }
    }
}
