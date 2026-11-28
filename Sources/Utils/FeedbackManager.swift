// SPDX-License-Identifier: AGPL-3.0-or-later
import UIKit
import AudioToolbox

/// Provides light haptic and sound feedback for key user actions.
///
/// Sounds are generated from pure PCM data at first use and cached to the app's
/// Caches directory. `AudioServicesPlaySystemSound` is used intentionally — it
/// respects the system mute switch and never touches `AVAudioSession`, which must
/// remain owned by `AudioKeepAlive`.
@MainActor
final class FeedbackManager {

    private let selectionGen   = UISelectionFeedbackGenerator()
    private let notificationGen = UINotificationFeedbackGenerator()
    private let impactGen      = UIImpactFeedbackGenerator(style: .light)

    var soundEnabled: Bool
    var hapticsEnabled: Bool

    init(soundEnabled: Bool = true, hapticsEnabled: Bool = true) {
        self.soundEnabled   = soundEnabled
        self.hapticsEnabled = hapticsEnabled
        // Warm up haptic engines on creation.
        selectionGen.prepare()
        notificationGen.prepare()
    }

    // MARK: - Public API

    /// Light selection tap — suitable for button presses or strip reorder.
    func tap() {
        if hapticsEnabled { selectionGen.selectionChanged() }
    }

    /// Incremental step — suitable for picker value changes.
    func step() {
        if hapticsEnabled { selectionGen.selectionChanged() }
    }

    /// Success feedback: plays a soft double-chime and a notification haptic.
    func success() {
        if hapticsEnabled { notificationGen.notificationOccurred(.success) }
        if soundEnabled   { playSound(.success) }
    }

    /// Warning feedback.
    func warning() {
        if hapticsEnabled { notificationGen.notificationOccurred(.warning) }
    }

    /// Error feedback.
    func error() {
        if hapticsEnabled { notificationGen.notificationOccurred(.error) }
    }

    // MARK: - Sound registry

    private enum SoundKey: String {
        case success = "ps_success"
    }

    private var soundIDs: [SoundKey: SystemSoundID] = [:]

    private func playSound(_ key: SoundKey) {
        if let sid = soundIDs[key] {
            AudioServicesPlaySystemSound(sid)
            return
        }
        Task { [weak self] in
            let sid = await Task.detached(priority: .utility) {
                Self.loadSystemSoundID(for: key)
            }.value
            guard sid != 0 else { return }
            self?.soundIDs[key] = sid
            AudioServicesPlaySystemSound(sid)
        }
    }

    // MARK: - WAV file helpers

    nonisolated private static func loadSystemSoundID(for key: SoundKey) -> SystemSoundID {
        guard let url = cachedSoundURL(for: key) else { return 0 }
        var sid: SystemSoundID = 0
        AudioServicesCreateSystemSoundID(url as CFURL, &sid)
        return sid
    }

    nonisolated private static func cachedSoundURL(for key: SoundKey) -> URL? {
        guard let caches = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let url = caches.appendingPathComponent("\(key.rawValue).wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let data: Data
        switch key {
        case .success: data = makeSuccessWAV()
        }
        try? data.write(to: url, options: .atomic)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - PCM generation

    /// Two-tone chime: 880 Hz (60 ms) → brief gap → 1047 Hz (80 ms), low volume.
    nonisolated private static func makeSuccessWAV() -> Data {
        let rate = 22050
        var samples = makeTone(freq: 880, durationMS: 60, sampleRate: rate, volume: 0.22)
        let gap = [Int16](repeating: 0, count: rate * 20 / 1000)
        samples += gap
        samples += makeTone(freq: 1047, durationMS: 80, sampleRate: rate, volume: 0.18)
        return buildWAV(samples: samples, sampleRate: rate)
    }

    nonisolated private static func makeTone(
        freq: Float, durationMS: Int, sampleRate: Int, volume: Float
    ) -> [Int16] {
        let count = sampleRate * durationMS / 1000
        let fadeLen = max(1, count / 6)
        return (0..<count).map { i in
            let t = Float(i) / Float(sampleRate)
            var env: Float
            if i < fadeLen        { env = Float(i) / Float(fadeLen) }
            else if i > count - fadeLen { env = Float(count - i) / Float(fadeLen) }
            else                  { env = 1.0 }
            let v = volume * env * sin(2 * .pi * freq * t)
            return Int16(clamping: Int(v * Float(Int16.max)))
        }
    }

    /// Builds a minimal RIFF/WAVE container around raw 16-bit mono PCM samples.
    nonisolated private static func buildWAV(samples: [Int16], sampleRate: Int) -> Data {
        let channels:   UInt16 = 1
        let bps:        UInt16 = 16
        let byteRate    = UInt32(sampleRate) * UInt32(channels) * UInt32(bps / 8)
        let blockAlign  = channels * (bps / 8)
        let dataSize    = UInt32(samples.count * 2)
        var d = Data()
        d += riff("RIFF", size: 36 + dataSize)
        d += [0x57, 0x41, 0x56, 0x45] // "WAVE"
        d += riff("fmt ", size: 16)
        d += le(UInt16(1))            // PCM
        d += le(channels)
        d += le(UInt32(sampleRate))
        d += le(byteRate)
        d += le(blockAlign)
        d += le(bps)
        d += riff("data", size: dataSize)
        for s in samples { d += le(UInt16(bitPattern: s)) }
        return d
    }

    nonisolated private static func riff(_ tag: String, size: UInt32) -> Data {
        var d = Data(tag.utf8)
        d += le(size)
        return d
    }

    nonisolated private static func le<T: FixedWidthInteger>(_ v: T) -> Data {
        withUnsafeBytes(of: v.littleEndian) { Data($0) }
    }
}
