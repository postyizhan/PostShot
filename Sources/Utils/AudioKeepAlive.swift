// SPDX-License-Identifier: AGPL-3.0-or-later
import AVFoundation
import Foundation

/// Keeps the host app alive in the background by playing continuous silent audio, and plays a
/// subtle non-visual two-note readiness cue when ReplayKit finishes its 3-second countdown.
final class AudioKeepAlive: ObservableObject, @unchecked Sendable {

    private let audioQueue = DispatchQueue(
        label: "com.postshot.audio-keep-alive",
        qos: .userInitiated
    )
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var silentBuffer: AVAudioPCMBuffer?
    private var cueBuffer: AVAudioPCMBuffer?
    private var isRunning = false

    /// Begins silent playback and activates the audio session. Idempotent.
    func start() {
        audioQueue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    /// Plays a short, gentle readiness chime mixed into the active background audio session so the
    /// user knows ReplayKit's hidden 3-second countdown has ended without showing any on-screen UI.
    func playStartCue() {
        audioQueue.async { [weak self] in
            self?.playStartCueOnQueue()
        }
    }

    /// Stops playback and deactivates the audio session. Idempotent.
    func stop() {
        audioQueue.async { [weak self] in
            self?.stopOnQueue()
        }
    }

    // MARK: - Serialized audioQueue operations

    private func startOnQueue() {
        guard !isRunning else { return }
        do {
            try configureSession(active: true)
            try startEngineLoop()
            isRunning = true
        } catch {
            isRunning = false
        }
    }

    private func playStartCueOnQueue() {
        if !isRunning { startOnQueue() }
        guard isRunning, let cue = cueBuffer, let silent = silentBuffer else { return }
        player.scheduleBuffer(cue, at: nil, options: .interrupts, completionHandler: nil)
        player.scheduleBuffer(silent, at: nil, options: .loops, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    private func stopOnQueue() {
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
        guard let silent = makeSilentBuffer(format: format) else { return }
        silentBuffer = silent
        cueBuffer = makeChimeBuffer(format: format)
        if player.engine == nil {
            engine.attach(player)
        }
        engine.connect(player, to: engine.outputNode, format: format)
        try engine.start()
        player.scheduleBuffer(silent, at: nil, options: .loops, completionHandler: nil)
        player.play()
    }

    private func makeSilentBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard format.channelCount > 0, format.sampleRate > 0 else { return nil }
        let frameCount = max(1, AVAudioFrameCount(format.sampleRate * 0.5))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount
        return buffer
    }

    /// Synthesizes a soft 90ms two-note chime (G5 → C6) with raised-cosine envelopes (no clicks).
    private func makeChimeBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard format.channelCount > 0, format.sampleRate > 0,
              let channels = format.channelCount as AVAudioChannelCount? else { return nil }
        let sr = format.sampleRate
        let totalFrames = max(1, Int(sr * 0.09))
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames)
        ), let floatData = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(totalFrames)
        let half = max(1, totalFrames / 2)
        for i in 0..<totalFrames {
            let localIdx = i < half ? i : (i - half)
            let localLen = i < half ? half : max(1, totalFrames - half)
            let freq = i < half ? 784.0 : 1046.5
            let env = 0.5 * (1.0 - cos(2.0 * .pi * Double(localIdx) / Double(localLen)))
            let sample = Float(0.12 * env * sin(2.0 * .pi * freq * Double(i) / sr))
            for ch in 0..<Int(channels) {
                floatData[ch][i] = sample
            }
        }
        return buffer
    }
}
