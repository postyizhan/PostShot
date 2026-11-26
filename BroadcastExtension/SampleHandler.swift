// SPDX-License-Identifier: AGPL-3.0-or-later
import ReplayKit
import CoreMedia
import CoreVideo
import Foundation

/// Broadcast Upload Extension entry point: dense keyframe selection and loopback streaming.
///
/// Streams ~8%-stride keyframes (`FrameSelector.Config.denseBroadcast`) over loopback TCP into the
/// host app's disk-backed `CaptureFrameStore` so `StitchEngine` has intermediate frames available
/// whenever a fast scroll or outlier frame requires gap backfill.
class SampleHandler: RPBroadcastSampleHandler {

    private struct PendingTail {
        let data: Data
        let signature: [Float]
        let timestamp: TimeInterval
    }

    private let bridge = FrameBridgeClient()
    private let selector = FrameSelector.Engine(config: .denseBroadcast)
    private let stateLock = NSLock()
    private var lastTimestamp: TimeInterval?
    private var pendingTail: PendingTail?
    private var lastTailSnapshotTime: TimeInterval = -.infinity

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        bridge.connect()
        bridge.sendControl("started")
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        autoreleasepool {
            guard bridge.canAcceptFrame,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

            guard let signature = FrameEncoder.signature(from: pixelBuffer) else { return }

            var tailToFlush: PendingTail?
            stateLock.lock()
            let timestamp = monotonicSeconds(of: sampleBuffer)
            if let tail = pendingTail, timestamp - tail.timestamp >= 0.55 {
                tailToFlush = tail
                pendingTail = nil
                selector.recordForcedKeep(signature: tail.signature, at: tail.timestamp)
            }
            let decision = selector.consider(signature, at: timestamp)
            // Snapshot only on sub-stride scroll endpoints (never on throttled active flicks) so
            // frame encoding never blocks high-velocity scrolling callbacks.
            let shouldSnapshotTail = (decision == .skipMinorChange)
                && (timestamp - lastTailSnapshotTime >= 0.35)
            if decision.isKeep {
                pendingTail = nil
            }
            stateLock.unlock()

            if let tailToFlush {
                _ = bridge.sendFrame(tailToFlush.data)
            }

            if decision.isKeep {
                if let encoded = FrameEncoder.encodedFrame(from: pixelBuffer) {
                    _ = bridge.sendFrame(encoded)
                }
            } else if shouldSnapshotTail, let encoded = FrameEncoder.encodedFrame(from: pixelBuffer) {
                stateLock.lock()
                pendingTail = PendingTail(data: encoded, signature: signature, timestamp: timestamp)
                lastTailSnapshotTime = timestamp
                stateLock.unlock()
            }
        }
    }

    override func broadcastFinished() {
        stateLock.lock()
        let finalTail = pendingTail
        pendingTail = nil
        if let finalTail {
            selector.recordForcedKeep(signature: finalTail.signature, at: finalTail.timestamp)
        }
        let count = selector.keptCount
        stateLock.unlock()

        if let finalTail {
            _ = bridge.sendFrame(finalTail.data)
        }
        bridge.finish(keptCount: count)
    }

    /// Monotonic presentation timestamp in seconds; advances by 1/60s when PTS is absent or
    /// non-monotonic so `FrameSelector`'s interval throttle can never stall on clock jumps.
    private func monotonicSeconds(of sampleBuffer: CMSampleBuffer) -> TimeInterval {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if pts.isNumeric {
            let seconds = CMTimeGetSeconds(pts)
            if seconds.isFinite {
                let clamped = lastTimestamp.map { max(seconds, $0) } ?? seconds
                lastTimestamp = clamped
                return clamped
            }
        }
        let next = (lastTimestamp ?? 0) + (1.0 / 60.0)
        lastTimestamp = next
        return next
    }
}
