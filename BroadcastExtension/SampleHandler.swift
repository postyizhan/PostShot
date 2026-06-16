// SPDX-License-Identifier: AGPL-3.0-or-later
import ReplayKit
import CoreMedia
import CoreVideo
import Foundation

/// Broadcast Upload Extension entry point — Phase 1: real frame capture + selection + transport.
///
/// Per video frame (SPEC_v2 §2 memory discipline):
///   1. Extract a cheap 64×64 grayscale signature (no full-resolution buffer).
///   2. Ask `FrameSelector.Engine` whether this frame is a keyframe.
///   3. ONLY for kept frames: encode full-resolution PNG, send over the socket, release immediately.
/// Resident memory stays at ~1 frame, well under the ~50 MB extension limit.
///
/// TEST PROTOCOL: keep PostShot in the FOREGROUND on its 录制 tab while recording so the app's
/// listener stays alive (background survival is a separate problem).
class SampleHandler: RPBroadcastSampleHandler {

    private let bridge = FrameBridgeClient()
    private let selector = FrameSelector.Engine()
    private var frameClock: TimeInterval = 0

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        bridge.connect()
        bridge.sendControl("started")
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let timestamp = presentationSeconds(of: sampleBuffer)

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let signature = FrameEncoder.signature(from: pixelBuffer) else { return }
        guard selector.consider(signature, at: timestamp).isKeep else { return }

        // Kept frame: pay the full-resolution encode cost, send, and let it deallocate.
        if let png = FrameEncoder.png(from: pixelBuffer) {
            bridge.sendFrame(png)
        }
    }

    override func broadcastFinished() {
        bridge.sendControl("finished \(selector.keptCount)")
        bridge.close()
    }

    /// Presentation timestamp in seconds; falls back to a synthetic ~60 fps clock if unavailable
    /// so `FrameSelector`'s min-interval throttle still has a monotonic time source.
    private func presentationSeconds(of sampleBuffer: CMSampleBuffer) -> TimeInterval {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if pts.isValid && !pts.isIndefinite {
            return CMTimeGetSeconds(pts)
        }
        frameClock += 1.0 / 60.0
        return frameClock
    }
}
