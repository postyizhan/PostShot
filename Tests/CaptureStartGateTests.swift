// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import PostShot

/// Deterministic unit tests for `CaptureStartGate` covering foreground app-switch waiting,
/// Control Center background starts with extra delay, immediate starts, and tail foreground pause.
final class CaptureStartGateTests: XCTestCase {

    func testForegroundStartWaitsForAppSwitchSettlesAndPausesOnReturn() {
        var gate = CaptureStartGate(waitForAppSwitch: true, extraDelaySeconds: 0)

        let initialReady = gate.broadcastDidStart(at: 10.0, isHostForeground: true)
        XCTAssertNil(initialReady, "Must wait until user switches out of PostShot")
        XCTAssertEqual(gate.phase(at: 10.0), .waitingForAppSwitch)
        XCTAssertFalse(gate.shouldAcceptFrame(at: 10.0))
        XCTAssertFalse(gate.shouldAcceptFrame(at: 12.0))
        XCTAssertFalse(gate.pollReadyCue(at: 12.0))

        // User switches out of PostShot at t = 12.5 -> 0.35s app-switcher settle window.
        let scheduled = gate.hostDidChangeForeground(false, at: 12.5)
        XCTAssertNotNil(scheduled)
        XCTAssertEqual(scheduled ?? 0, 12.85, accuracy: 1e-6)
        XCTAssertFalse(gate.shouldAcceptFrame(at: 12.80))
        XCTAssertFalse(gate.pollReadyCue(at: 12.80))

        // Gate opens at t = 12.85 and fires readiness cue exactly once.
        XCTAssertTrue(gate.pollReadyCue(at: 12.85))
        XCTAssertFalse(gate.pollReadyCue(at: 13.0), "Ready cue must only fire once per session")
        XCTAssertTrue(gate.shouldAcceptFrame(at: 12.85))
        XCTAssertEqual(gate.phase(at: 13.0), .recording)

        // Returning to PostShot at the tail immediately pauses frame acceptance.
        XCTAssertNil(gate.hostDidChangeForeground(true, at: 20.0))
        XCTAssertTrue(gate.isPausedInHostForeground)
        XCTAssertEqual(gate.phase(at: 20.0), .pausedInHostForeground)
        XCTAssertFalse(gate.shouldAcceptFrame(at: 20.0))

        // Leaving PostShot again during the same broadcast resumes without re-chiming.
        XCTAssertNil(gate.hostDidChangeForeground(false, at: 22.0))
        XCTAssertTrue(gate.shouldAcceptFrame(at: 22.0))
        XCTAssertFalse(gate.pollReadyCue(at: 22.0))
    }

    func testForegroundStartUsesLargerConfiguredDelayAfterAppSwitch() {
        var gate = CaptureStartGate(waitForAppSwitch: true, extraDelaySeconds: 3)

        XCTAssertNil(gate.broadcastDidStart(at: 0.0, isHostForeground: true))
        let scheduled = gate.hostDidChangeForeground(false, at: 4.0)
        XCTAssertEqual(scheduled ?? 0, 7.0, accuracy: 1e-6)

        XCTAssertFalse(gate.shouldAcceptFrame(at: 6.99))
        XCTAssertFalse(gate.pollReadyCue(at: 6.99))
        XCTAssertTrue(gate.pollReadyCue(at: 7.0))
        XCTAssertTrue(gate.shouldAcceptFrame(at: 7.0))
    }

    func testControlCenterBackgroundStartRespectsExtraDelay() {
        var gate = CaptureStartGate(waitForAppSwitch: true, extraDelaySeconds: 2)

        let readyAt = gate.broadcastDidStart(at: 50.0, isHostForeground: false)
        XCTAssertEqual(readyAt ?? 0, 52.0, accuracy: 1e-6)
        XCTAssertEqual(gate.phase(at: 50.5), .countingDown(readyAt: 52.0))

        XCTAssertFalse(gate.shouldAcceptFrame(at: 50.0))
        XCTAssertFalse(gate.shouldAcceptFrame(at: 51.99))
        XCTAssertFalse(gate.pollReadyCue(at: 51.99))

        XCTAssertTrue(gate.pollReadyCue(at: 52.0))
        XCTAssertFalse(gate.pollReadyCue(at: 52.5))
        XCTAssertTrue(gate.shouldAcceptFrame(at: 52.0))
        XCTAssertEqual(gate.phase(at: 52.0), .recording)
    }

    func testControlCenterBackgroundStartWithZeroDelayOpensImmediately() {
        var gate = CaptureStartGate(waitForAppSwitch: true, extraDelaySeconds: 0)

        let readyAt = gate.broadcastDidStart(at: 30.0, isHostForeground: false)
        XCTAssertEqual(readyAt ?? -1, 30.0, accuracy: 1e-6)
        XCTAssertTrue(gate.pollReadyCue(at: 30.0))
        XCTAssertTrue(gate.shouldAcceptFrame(at: 30.0))
    }

    func testWaitForAppSwitchDisabledWithZeroDelayIsImmediatelyReadyInForeground() {
        var gate = CaptureStartGate(waitForAppSwitch: false, extraDelaySeconds: 0)

        let readyAt = gate.broadcastDidStart(at: 5.0, isHostForeground: true)
        XCTAssertEqual(readyAt ?? -1, 5.0, accuracy: 1e-6)
        XCTAssertTrue(gate.pollReadyCue(at: 5.0))
        XCTAssertFalse(gate.pollReadyCue(at: 5.1))
        XCTAssertTrue(gate.shouldAcceptFrame(at: 5.0))

        // Remaining in foreground does not pause when waitForAppSwitch is false.
        XCTAssertNil(gate.hostDidChangeForeground(true, at: 6.0))
        XCTAssertFalse(gate.isPausedInHostForeground)
        XCTAssertTrue(gate.shouldAcceptFrame(at: 6.0))
    }

    func testBroadcastFinishResetsSessionCleanly() {
        var gate = CaptureStartGate(waitForAppSwitch: false, extraDelaySeconds: 0)
        _ = gate.broadcastDidStart(at: 1.0, isHostForeground: true)
        XCTAssertTrue(gate.pollReadyCue(at: 1.0))
        XCTAssertTrue(gate.shouldAcceptFrame(at: 1.0))

        gate.broadcastDidFinish()
        XCTAssertEqual(gate.phase(at: 2.0), .idle)
        XCTAssertFalse(gate.shouldAcceptFrame(at: 2.0))
        XCTAssertFalse(gate.pollReadyCue(at: 2.0))

        // Next session can arm and fire its own ready cue again.
        _ = gate.broadcastDidStart(at: 10.0, isHostForeground: true)
        XCTAssertTrue(gate.pollReadyCue(at: 10.0))
        XCTAssertTrue(gate.shouldAcceptFrame(at: 10.0))
    }

    func testGateBoxStagesLatestCountdownFrameInTargetAppAndDropsForegroundFrames() {
        let box = CaptureStartGateBox(waitForAppSwitch: true, extraDelaySeconds: 2, isHostForeground: true)
        _ = box.startBroadcast(at: 0.0)
        // Frames sent while still inside PostShot foreground must never be staged or accepted.
        XCTAssertNil(box.receiveFrame(Data([0xAA]), at: 0.5))

        // User switches to target app at t = 1.0 -> readyAt = 3.0.
        XCTAssertEqual(box.setHostForeground(false, at: 1.0) ?? 0, 3.0, accuracy: 1e-6)
        // Early navigation frame at t = 1.4, then final static head frame at t = 2.1.
        XCTAssertNil(box.receiveFrame(Data([0x01]), at: 1.4))
        XCTAssertNil(box.receiveFrame(Data([0x02]), at: 2.1))
        XCTAssertNil(box.drainStagedFrameIfOpen(at: 2.9))

        // At t = 3.0 gate opens: draining yields ONLY the latest target-app head frame (0x02).
        let drained = box.drainStagedFrameIfOpen(at: 3.0)
        XCTAssertEqual(drained?.payload, Data([0x02]))
        XCTAssertNil(box.drainStagedFrameIfOpen(at: 3.1), "Must drain staged frame only once")
    }
}
