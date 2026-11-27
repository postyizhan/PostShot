// SPDX-License-Identifier: AGPL-3.0-or-later
import ReplayKit
import CoreMedia
import CoreVideo
import Foundation

/// Broadcast Upload Extension entry point: dense keyframe selection and loopback streaming.
///
/// Streams ~8%-stride keyframes (`FrameSelector.Config.denseBroadcast`) over loopback TCP into the
/// host app's disk-backed `CaptureFrameStore`, and flushes static resting frames (such as the
/// clean page head revealed right after Control Center closes on a ProMotion display).
class SampleHandler: RPBroadcastSampleHandler {

    private struct PendingTail {
        let data: Data
        let signature: [Float]
        let timestamp: TimeInterval
    }

    private static let denseConfig = FrameSelector.Config.denseBroadcast
    private let bridge = FrameBridgeClient()
    private let selector = FrameSelector.Engine(config: denseConfig)
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
            if let tail = pendingTail, shouldFlushTail(tail, currentSignature: signature, at: timestamp) {
                tailToFlush = tail
                pendingTail = nil
                selector.recordForcedKeep(signature: tail.signature, at: tail.timestamp)
            }
            let decision = selector.consider(signature, at: timestamp)
            if decision.isKeep {
                pendingTail = nil
                lastTailSnapshotTime = timestamp
            }
            let shouldSnapshotTail = (decision == .skipThrottled || decision == .skipMinorChange)
                && (timestamp - lastTailSnapshotTime >= 0.06)
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

    /// Flushes `pendingTail` either when ProMotion paused frame delivery for `>= 0.22s` (e.g.
    /// resting on the static page head right after Control Center closed) or when the screen
    /// stabilized onto `pendingTail` for `>= 0.10s`.
    private func shouldFlushTail(
        _ tail: PendingTail, currentSignature: [Float], at timestamp: TimeInterval
    ) -> Bool {
        let elapsed = timestamp - tail.timestamp
        if elapsed >= 0.22 { return true }
        return elapsed >= 0.10
            && FrameSelector.meanAbsDiff(currentSignature, tail.signature) < Self.denseConfig.duplicateThreshold
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
