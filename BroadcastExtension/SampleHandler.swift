// SPDX-License-Identifier: AGPL-3.0-or-later
import ReplayKit
import CoreMedia

/// Broadcast Upload Extension entry point — socket-bridge smoke test (Phase 0, attempt 2).
///
/// App Group sharing is unavailable under free-signed sideloads (CaptureView diagnostics proved
/// the container is nil). This version instead opens a loopback TCP connection to the main app
/// and streams text messages, to verify the extension→app channel works at all.
///
/// IMPORTANT TEST PROTOCOL: keep PostShot in the FOREGROUND on its 录制 tab while recording
/// (do NOT switch to another app). That keeps the app's listener alive so this smoke test
/// isolates the socket bridge itself, independent of the separate background-survival problem.
class SampleHandler: RPBroadcastSampleHandler {

    private let bridge = FrameBridgeClient()
    private var frameCounter = 0

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        bridge.connect()
        // Give the connection a moment, then announce ourselves.
        bridge.send("hello from extension")
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        frameCounter += 1
        // Throttle: report every 10th frame so we don't flood the smoke-test channel.
        if frameCounter % 10 == 0 {
            bridge.send("frame \(frameCounter)")
        }
    }

    override func broadcastFinished() {
        bridge.send("finished total \(frameCounter)")
        bridge.close()
    }
}
