// SPDX-License-Identifier: AGPL-3.0-or-later
import AVFoundation
import Foundation

/// Keeps the host app alive in the background by playing continuous silent audio.
///
/// Screen-recording capture uses a loopback TCP socket that requires both the host app and the
/// broadcast extension to stay running while the user scrolls another app. App Groups are
/// unavailable under free-account sideloading, so an active `.playback` + `.mixWithOthers` audio
/// session prevents iOS from suspending the backgrounded listener without interrupting target apps.
@MainActor
final class AudioKeepAlive: ObservableObject {

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
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(active, options: .notifyOthersOnDeactivation)
    }

    private func startEngineLoop() throws {
        let format = engine.outputNode.inputFormat(forBus: 0)
        guard let buffer = makeSilentBuffer(format: format) else { return }
        if player.engine == nil {
            engine.attach(player)
        }
        engine.connect(player, to: engine.outputNode, format: format)
        try engine.start()
        player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        player.play()
    }

    /// A short buffer of silence in the engine's output format, or `nil` if the route is invalid.
    private func makeSilentBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard format.channelCount > 0, format.sampleRate > 0 else { return nil }
        let frameCount = max(1, AVAudioFrameCount(format.sampleRate * 0.5))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount
        return buffer
    }
}
