// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Pure, deterministic state machine that gates incoming broadcast frames and schedules the
/// readiness cue so PostShot never captures its own UI or app-switcher transitions.
struct CaptureStartGate: Sendable {
    /// Minimum settle window after leaving PostShot so the iOS app-switcher animation finishes.
    static let appSwitchSettleFloor: TimeInterval = 0.35

    enum Phase: Equatable, Sendable {
        case idle
        case waitingForAppSwitch
        case countingDown(readyAt: TimeInterval)
        case recording
        case pausedInHostForeground
    }

    var waitForAppSwitch: Bool = true
    var extraDelaySeconds: TimeInterval = 0

    private(set) var isBroadcastActive = false
    private(set) var isHostForeground = true
    private(set) var readyAt: TimeInterval?
    private(set) var didFireReadyCue = false

    init(waitForAppSwitch: Bool = true, extraDelaySeconds: TimeInterval = 0) {
        self.waitForAppSwitch = waitForAppSwitch
        self.extraDelaySeconds = max(0, extraDelaySeconds)
    }

    var isPausedInHostForeground: Bool {
        isBroadcastActive && waitForAppSwitch && isHostForeground && readyAt != nil
    }

    /// Starts a new broadcast session and returns `readyAt` if the countdown can begin immediately,
    /// or `nil` when waiting for the user to leave PostShot first.
    mutating func broadcastDidStart(at now: TimeInterval, isHostForeground: Bool) -> TimeInterval? {
        isBroadcastActive = true
        self.isHostForeground = isHostForeground
        didFireReadyCue = false
        if waitForAppSwitch && isHostForeground {
            readyAt = nil
            return nil
        }
        let target = now + max(0, extraDelaySeconds)
        readyAt = target
        return target
    }

    /// Updates host foreground state; when leaving PostShot during an active broadcast that has not
    /// opened yet, schedules `readyAt = now + max(0.35, extraDelaySeconds)` and returns it.
    mutating func hostDidChangeForeground(_ isForeground: Bool, at now: TimeInterval) -> TimeInterval? {
        let wasOpen: Bool
        if let scheduled = readyAt, now >= scheduled, !(waitForAppSwitch && isHostForeground) {
            wasOpen = true
        } else {
            wasOpen = didFireReadyCue
        }
        isHostForeground = isForeground
        guard isBroadcastActive else { return nil }
        if isForeground {
            if waitForAppSwitch && !wasOpen {
                readyAt = nil
            }
            return nil
        }
        guard readyAt == nil else { return nil }
        let delay = waitForAppSwitch
            ? max(Self.appSwitchSettleFloor, extraDelaySeconds)
            : max(0, extraDelaySeconds)
        let target = now + delay
        readyAt = target
        return target
    }

    /// Updates user-configurable start settings and adjusts any pending pre-open gate schedule.
    mutating func updateConfiguration(
        waitForAppSwitch: Bool, extraDelaySeconds: TimeInterval, at now: TimeInterval
    ) -> TimeInterval? {
        self.waitForAppSwitch = waitForAppSwitch
        self.extraDelaySeconds = max(0, extraDelaySeconds)
        guard isBroadcastActive else { return nil }
        if !waitForAppSwitch && readyAt == nil {
            let target = now + self.extraDelaySeconds
            readyAt = target
            return target
        }
        if waitForAppSwitch && isHostForeground && !didFireReadyCue,
           let scheduled = readyAt, now < scheduled {
            readyAt = nil
        }
        return nil
    }

    /// Returns `true` at most once per broadcast session when the gate first becomes ready.
    mutating func pollReadyCue(at now: TimeInterval) -> Bool {
        guard isBroadcastActive, !didFireReadyCue, let readyAt, now >= readyAt else {
            return false
        }
        guard !waitForAppSwitch || !isHostForeground else {
            return false
        }
        didFireReadyCue = true
        return true
    }

    /// Returns `true` iff broadcast is active, the start gate has opened, and host foreground
    /// auto-pause is not engaged.
    func shouldAcceptFrame(at now: TimeInterval) -> Bool {
        guard isBroadcastActive, let readyAt, now >= readyAt else {
            return false
        }
        return !(waitForAppSwitch && isHostForeground)
    }

    func phase(at now: TimeInterval) -> Phase {
        guard isBroadcastActive else { return .idle }
        guard let readyAt else { return .waitingForAppSwitch }
        if waitForAppSwitch && isHostForeground {
            return .pausedInHostForeground
        }
        return now < readyAt ? .countingDown(readyAt: readyAt) : .recording
    }

    mutating func broadcastDidFinish() {
        isBroadcastActive = false
        readyAt = nil
        didFireReadyCue = false
    }
}

/// Thread-safe lock-protected box around `CaptureStartGate` for cross-queue frame filtering.
final class CaptureStartGateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var gate: CaptureStartGate
    private var hostForeground: Bool
    private var sessionID: UInt64 = 0
    /// Holds only the single latest frame received during `.countingDown` (while already in the
    /// target app) so a static page head sent by the extension before the chime is never lost.
    private var stagedCountdownFrame: Data?

    init(waitForAppSwitch: Bool, extraDelaySeconds: Int, isHostForeground: Bool) {
        self.gate = CaptureStartGate(
            waitForAppSwitch: waitForAppSwitch,
            extraDelaySeconds: TimeInterval(extraDelaySeconds)
        )
        self.hostForeground = isHostForeground
    }

    var isBroadcastActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return gate.isBroadcastActive
    }

    func updateSettings(
        waitForAppSwitch: Bool, extraDelaySeconds: Int, at now: TimeInterval
    ) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return gate.updateConfiguration(
            waitForAppSwitch: waitForAppSwitch,
            extraDelaySeconds: TimeInterval(extraDelaySeconds),
            at: now
        )
    }

    func setHostForeground(_ isForeground: Bool, at now: TimeInterval) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        hostForeground = isForeground
        if isForeground && gate.waitForAppSwitch {
            stagedCountdownFrame = nil
        }
        return gate.hostDidChangeForeground(isForeground, at: now)
    }

    func startBroadcast(at now: TimeInterval) -> (sessionID: UInt64, readyAt: TimeInterval?) {
        lock.lock()
        defer { lock.unlock() }
        sessionID &+= 1
        stagedCountdownFrame = nil
        let readyAt = gate.broadcastDidStart(at: now, isHostForeground: hostForeground)
        return (sessionID, readyAt)
    }

    func finishBroadcast() {
        lock.lock()
        defer { lock.unlock() }
        stagedCountdownFrame = nil
        gate.broadcastDidFinish()
    }

    func bumpSessionAndReset() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        sessionID &+= 1
        stagedCountdownFrame = nil
        gate.broadcastDidFinish()
        return sessionID
    }

    /// Evaluates an incoming frame: accepts immediately if open (prepending any unflushed staged
    /// countdown frame), stages the latest target-app frame during `.countingDown`, or drops it.
    func receiveFrame(_ data: Data, at now: TimeInterval) -> (sessionID: UInt64, payloads: [Data])? {
        lock.lock()
        defer { lock.unlock() }
        if gate.shouldAcceptFrame(at: now) {
            if let staged = stagedCountdownFrame {
                stagedCountdownFrame = nil
                return (sessionID, [staged, data])
            }
            return (sessionID, [data])
        }
        if case .countingDown = gate.phase(at: now) {
            stagedCountdownFrame = data
        }
        return nil
    }

    /// Drains the staged target-app frame once the countdown gate has opened.
    func drainStagedFrameIfOpen(at now: TimeInterval) -> (sessionID: UInt64, payload: Data)? {
        lock.lock()
        defer { lock.unlock() }
        guard gate.shouldAcceptFrame(at: now), let staged = stagedCountdownFrame else { return nil }
        stagedCountdownFrame = nil
        return (sessionID, staged)
    }

    func pollReadyAndPhase(at now: TimeInterval) -> (shouldPlayCue: Bool, phase: CaptureStartGate.Phase) {
        lock.lock()
        defer { lock.unlock() }
        let cue = gate.pollReadyCue(at: now)
        return (cue, gate.phase(at: now))
    }
}
