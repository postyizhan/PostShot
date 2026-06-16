// SPDX-License-Identifier: AGPL-3.0-or-later
import AVFoundation
import Foundation

/// Keeps the host app alive in the background by playing continuous silent audio.
///
/// WHY: v2's frame transport is a loopback socket that requires BOTH the host app and the broadcast
/// extension to be running. But screen-recording means the user leaves PostShot to scroll another
/// app, and iOS suspends the backgrounded host within seconds — killing the socket (only the first
/// few frames arrive). App Groups, the clean alternative, are unavailable under free-signed
/// sideloads (verified on-device: container is nil). So the only path is to prevent host suspension.
///
/// HOW: an audio app with an active `AVAudioSession` and the `audio` background mode stays running in
/// the background. We play generated silent PCM (no bundled file — Windows-friendly CI) on a loop,
/// using `.playback` + `.mixWithOthers` so we don't interrupt the recorded app's own audio.
///
/// CAVEAT: this is a best-effort keep-alive. Whether it survives reliably during a ReplayKit session
/// is the open question this whole approach is testing on-device.
@MainActor
final class AudioKeepAlive {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var isRunning = false

    /// Begins silent playback and activates the audio session. Idempotent.
    func start() {
        guard !isRunning else { return }
        do {
            try configureSession(active: true)
            try startEngineLoop()
            isRunning = true
        } catch {
            // Non-fatal: keep-alive failing just means background survival isn't guaranteed.
            isRunning = false
        }
    }

    /// Stops playback and deactivates the audio session. Idempotent.
    func stop() {
        guard isRunning else { return }
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRunning = false
    }

    // MARK: - Setup

    private func configureSession(active: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        // .playback keeps audio alive in background; .mixWithOthers avoids interrupting the
        // recorded app's audio (and avoids ducking the system).
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(active, options: .notifyOthersOnDeactivation)
    }

    private func startEngineLoop() throws {
        let format = engine.outputNode.inputFormat(forBus: 0)
        engine.attach(player)
        engine.connect(player, to: engine.outputNode, format: format)

        let buffer = makeSilentBuffer(format: format)
        try engine.start()
        // Loop the silent buffer indefinitely so the session never goes idle.
        player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        player.play()
    }

    /// A short buffer of silence in the engine's output format.
    private func makeSilentBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(format.sampleRate * 0.5) // 0.5s of silence, looped
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        // AVAudioPCMBuffer zero-initializes its channel data, so it is already silent.
        return buffer
    }
}
