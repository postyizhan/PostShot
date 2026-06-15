// SPDX-License-Identifier: AGPL-3.0-or-later
import ReplayKit
import CoreMedia
import CoreVideo
import CoreGraphics

/// Broadcast Upload Extension entry point (Phase 0 minimal version).
///
/// Goal of Phase 0 is ONLY to prove the sideload path: that a build carrying an app-extension
/// target + App Group entitlement can be signed by a free Apple ID (via 爱思/AltStore) and that
/// the extension can hand a frame to the main app through the shared container. The real
/// frame-selection algorithm arrives in Phase 1.
///
/// Memory discipline (the 50MB extension ceiling, SPEC v2 §2) is honored even here: we convert
/// at most one frame to a CGImage, write it, and never retain pixel buffers.
class SampleHandler: RPBroadcastSampleHandler {

    private var frameCounter = 0
    private var didWriteProbeFrame = false

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        // Clear any frames from a previous session so each recording starts clean.
        try? FrameStore.reset()
        frameCounter = 0
        didWriteProbeFrame = false
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        frameCounter += 1

        // Phase 0: write exactly one real frame to prove the App Group write path works
        // end-to-end. (Phase 1 replaces this with FrameSelector deciding which frames to keep.)
        guard !didWriteProbeFrame else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let cgImage = Self.makeCGImage(from: pixelBuffer) else { return }
        try? FrameStore.write(cgImage, index: 0)
        didWriteProbeFrame = true
        // cgImage / pixelBuffer go out of scope here — nothing retained.
    }

    override func broadcastFinished() {
        // Stash the observed frame count so the app can display "received N frames".
        if let defaults = UserDefaults(suiteName: AppGroup.identifier) {
            defaults.set(frameCounter, forKey: "lastBroadcastFrameCount")
        }
    }

    /// Converts a video `CVPixelBuffer` to a `CGImage` via Core Graphics, no external deps.
    private static func makeCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // ReplayKit delivers BGRA; matching bitmap info avoids a channel swap.
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let ctx = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }
        return ctx.makeImage()
    }
}
