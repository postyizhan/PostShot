// SPDX-License-Identifier: AGPL-3.0-or-later
import ReplayKit
import CoreMedia
import CoreVideo
import Foundation

/// Broadcast Upload Extension entry point: real-time keyframe selection and loopback streaming.
///
/// Per video frame:
///   1. Extract a cheap 64×64 grayscale signature inside an `autoreleasepool`.
///   2. Ask `FrameSelector.Engine` whether this frame has scrolled enough to be a keyframe.
///   3. ONLY for kept frames: encode full-resolution PNG, enqueue over loopback TCP, and release.
/// Resident memory stays at ~1–2 frames, well under the ~50 MB extension limit.
///
/// The host app keeps its loopback TCP listener alive in the background via `AudioKeepAlive`
/// while the user switches to the target app and scrolls.
class SampleHandler: RPBroadcastSampleHandler {

    private let bridge = FrameBridgeClient()
    private let selector = FrameSelector.Engine()
    private let stateLock = NSLock()
    private var lastTimestamp: TimeInterval?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        bridge.connect()
        bridge.sendControl("started")
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        autoreleasepool {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

            guard let signature = FrameEncoder.signature(from: pixelBuffer) else { return }

            stateLock.lock()
            let timestamp = monotonicSeconds(of: sampleBuffer)
            let decision = selector.consider(signature, at: timestamp)
            stateLock.unlock()

            guard decision.isKeep, let png = FrameEncoder.png(from: pixelBuffer) else { return }
            _ = bridge.sendFrame(png)
        }
    }

    override func broadcastFinished() {
        stateLock.lock()
        let count = selector.keptCount
        stateLock.unlock()
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
