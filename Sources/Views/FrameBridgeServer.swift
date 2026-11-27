// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Network
import UIKit

/// Main-app side of the loopback frame bridge: receives length-prefixed `FrameProtocol` messages
/// from the broadcast extension, gates pre-switch / countdown / foreground frames via
/// `CaptureStartGate`, and streams accepted payloads directly into `CaptureFrameStore` on disk.
@MainActor
final class FrameBridgeServer: ObservableObject {
    struct CapturedPreview: Identifiable {
        let id = UUID()
        let poolIndex: Int
        let thumbnail: UIImage
    }

    private enum Keys {
        static let waitForAppSwitch = "capture.waitForAppSwitch"
        static let extraDelaySeconds = "capture.extraDelaySeconds"
    }

    let frameStore = CaptureFrameStore()
    var onBroadcastStarted: (() -> Void)?
    var onBroadcastReady: (() -> Void)?
    var onBroadcastFinished: (() -> Void)?

    @Published var waitForAppSwitch: Bool {
        didSet { persistAndSyncSettings() }
    }
    @Published var extraDelaySeconds: Int {
        didSet { persistAndSyncSettings() }
    }

    @Published private(set) var status = "未启动"
    @Published private(set) var previews: [CapturedPreview] = []
    @Published private(set) var lastControl = "(无)"
    @Published private(set) var isFinished = false

    var frameCount: Int { previews.count }

    private let userDefaults: UserDefaults
    private let gateBox: CaptureStartGateBox
    private let transport = Transport()
    private var observers: [NSObjectProtocol] = []
    private var readyTimerTask: Task<Void, Never>?
    private var activeSessionID: UInt64 = 0

    init(defaults: UserDefaults = .standard) {
        let waitSwitch = defaults.object(forKey: Keys.waitForAppSwitch) as? Bool ?? true
        let rawDelay = defaults.object(forKey: Keys.extraDelaySeconds) as? Int ?? 0
        let delay = [0, 1, 2, 3, 5].contains(rawDelay) ? rawDelay : 0
        self.userDefaults = defaults
        self.waitForAppSwitch = waitSwitch
        self.extraDelaySeconds = delay
        let isFG = UIApplication.shared.applicationState != .background
        self.gateBox = CaptureStartGateBox(
            waitForAppSwitch: waitSwitch, extraDelaySeconds: delay, isHostForeground: isFG
        )
        observeAppLifecycle()
    }

    deinit {
        readyTimerTask?.cancel()
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func start() {
        transport.start(store: frameStore, gateBox: gateBox) { [weak self] event in
            Task { @MainActor in self?.handleEvent(event) }
        }
    }

    func stop() {
        readyTimerTask?.cancel()
        transport.stop()
    }

    /// Clears collected frames and disk files for a fresh recording (keeps listener running).
    func reset() {
        readyTimerTask?.cancel()
        activeSessionID = gateBox.bumpSessionAndReset()
        frameStore.reset()
        previews.removeAll()
        lastControl = "(无)"
        isFinished = false
    }

    // MARK: - Lifecycle & Gate Synchronization

    private func observeAppLifecycle() {
        let nc = NotificationCenter.default
        let pairs: [(Notification.Name, Bool)] = [
            (UIApplication.didEnterBackgroundNotification, false),
            (UIApplication.willEnterForegroundNotification, true),
            (UIApplication.didBecomeActiveNotification, true),
        ]
        for (name, isFG) in pairs {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.handleForegroundChange(isFG) }
            })
        }
    }

    private func persistAndSyncSettings() {
        userDefaults.set(waitForAppSwitch, forKey: Keys.waitForAppSwitch)
        userDefaults.set(extraDelaySeconds, forKey: Keys.extraDelaySeconds)
        let now = ProcessInfo.processInfo.systemUptime
        if let scheduled = gateBox.updateSettings(
            waitForAppSwitch: waitForAppSwitch, extraDelaySeconds: extraDelaySeconds, at: now
        ) {
            scheduleReadyTimer(until: scheduled)
        } else {
            syncStatusFromGate()
        }
    }

    private func handleForegroundChange(_ isForeground: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if let scheduled = gateBox.setHostForeground(isForeground, at: now) {
            scheduleReadyTimer(until: scheduled)
        } else {
            if isForeground && waitForAppSwitch {
                readyTimerTask?.cancel()
            }
            syncStatusFromGate()
        }
    }

    private func scheduleReadyTimer(until readyAt: TimeInterval?) {
        readyTimerTask?.cancel()
        syncStatusFromGate()
        guard let readyAt else { return }
        let remaining = readyAt - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return }
        readyTimerTask = Task { @MainActor [weak self] in
            let nanos = UInt64((remaining + 0.02) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            self?.syncStatusFromGate()
        }
    }

    private func syncStatusFromGate() {
        let snapshot = gateBox.pollReadyAndPhase(at: ProcessInfo.processInfo.systemUptime)
        if snapshot.shouldPlayCue {
            transport.flushStagedFrame(store: frameStore, gateBox: gateBox) { [weak self] event in
                Task { @MainActor in self?.handleEvent(event) }
            }
            onBroadcastReady?()
        }
        switch snapshot.phase {
        case .idle:
            break
        case .waitingForAppSwitch:
            status = "已连接 · 请切到目标 App（切出后自动开录）"
            lastControl = "等待切出本软件"
        case .countingDown(let readyAt):
            status = "准备开录（倒计时 \(extraDelaySeconds)s）…"
            lastControl = "倒计时 \(extraDelaySeconds)s"
            if readyTimerTask == nil {
                scheduleReadyTimer(until: readyAt)
            }
        case .recording:
            status = "录制采集中 🔴"
            lastControl = "录制进行中"
        case .pausedInHostForeground:
            status = "已暂停采帧（已返回本软件）"
            lastControl = "前台自动暂停采帧"
        }
    }

    // MARK: - Transport Events

    private func adoptSession(_ sessionID: UInt64) {
        guard activeSessionID != sessionID else { return }
        activeSessionID = sessionID
        previews.removeAll()
        isFinished = false
    }

    private func handleEvent(_ event: Transport.Event) {
        switch event {
        case .state(let text):
            if !gateBox.isBroadcastActive { status = text }
        case .connected:
            isFinished = false
            if !gateBox.isBroadcastActive { status = "扩展已连接 ✅" }
        case .started(let sessionID, let readyAt):
            guard sessionID >= activeSessionID else { return }
            adoptSession(sessionID)
            onBroadcastStarted?()
            scheduleReadyTimer(until: readyAt)
        case .frameStored(let sessionID, let index, let thumbnail):
            guard sessionID >= activeSessionID else { return }
            adoptSession(sessionID)
            previews.append(CapturedPreview(poolIndex: index, thumbnail: thumbnail))
            syncStatusFromGate()
        case .control(let raw):
            handleControl(raw)
        }
    }

    private func handleControl(_ raw: String) {
        if raw.hasPrefix("finished") {
            readyTimerTask?.cancel()
            status = "录制已结束 ✅"
            lastControl = "已完成（采集 \(previews.count) 帧）"
            isFinished = true
            onBroadcastFinished?()
        } else {
            lastControl = raw.isEmpty ? "(空)" : raw
        }
    }
}

/// Serial-queue-isolated socket listener and per-connection decoder state so `NWConnection`
/// never crosses `@MainActor` boundaries on iOS 16.
private final class Transport: @unchecked Sendable {
    enum Event: Sendable {
        case state(String)
        case connected
        case started(sessionID: UInt64, readyAt: TimeInterval?)
        case frameStored(sessionID: UInt64, index: Int, thumbnail: UIImage)
        case control(String)
    }

    private let queue = DispatchQueue(label: "com.postshot.bridge.server", qos: .userInitiated)
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: (conn: NWConnection, decoder: FrameProtocol.Decoder)] = [:]

    func start(
        store: CaptureFrameStore,
        gateBox: CaptureStartGateBox,
        onEvent: @escaping @Sendable (Event) -> Void
    ) {
        queue.async { [weak self] in
            self?.startListener(store: store, gateBox: gateBox, onEvent: onEvent)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            self.sessions.values.forEach { $0.conn.cancel() }
            self.sessions.removeAll()
        }
    }

    func flushStagedFrame(
        store: CaptureFrameStore,
        gateBox: CaptureStartGateBox,
        onEvent: @escaping @Sendable (Event) -> Void
    ) {
        queue.async {
            let now = ProcessInfo.processInfo.systemUptime
            guard let drained = gateBox.drainStagedFrameIfOpen(at: now),
                  let saved = store.append(drained.payload) else { return }
            onEvent(.frameStored(sessionID: drained.sessionID, index: saved.index, thumbnail: saved.thumbnail))
        }
    }

    private func startListener(
        store: CaptureFrameStore,
        gateBox: CaptureStartGateBox,
        onEvent: @escaping @Sendable (Event) -> Void
    ) {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.acceptLocalOnly = true
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: FrameBridge.port)!)
            self.listener = listener
            onEvent(.state("启动中…"))
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: onEvent(.state("监听中 (127.0.0.1:\(FrameBridge.port))"))
                case .failed(let err): onEvent(.state("监听失败：\(err.localizedDescription)"))
                case .cancelled: onEvent(.state("已停止"))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                self?.accept(conn, store: store, gateBox: gateBox, onEvent: onEvent)
            }
            listener.start(queue: queue)
        } catch {
            onEvent(.state("无法创建监听：\(error.localizedDescription)"))
        }
    }

    private func accept(
        _ conn: NWConnection,
        store: CaptureFrameStore,
        gateBox: CaptureStartGateBox,
        onEvent: @escaping @Sendable (Event) -> Void
    ) {
        let id = ObjectIdentifier(conn)
        sessions[id] = (conn, FrameProtocol.Decoder())
        onEvent(.connected)
        conn.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.sessions.removeValue(forKey: id) }
            if case .cancelled = state { self?.sessions.removeValue(forKey: id) }
        }
        conn.start(queue: queue)
        receiveLoop(id: id, store: store, gateBox: gateBox, onEvent: onEvent)
    }

    private func receiveLoop(
        id: ObjectIdentifier,
        store: CaptureFrameStore,
        gateBox: CaptureStartGateBox,
        onEvent: @escaping @Sendable (Event) -> Void
    ) {
        guard let conn = sessions[id]?.conn else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, let entry = self.sessions[id] else { return }
            if let data, !data.isEmpty {
                do {
                    for msg in try entry.decoder.push(data) {
                        self.route(msg, store: store, gateBox: gateBox, onEvent: onEvent)
                    }
                } catch {
                    entry.decoder.reset()
                    entry.conn.cancel()
                    self.sessions.removeValue(forKey: id)
                    onEvent(.state("协议解码错误，连接已重置"))
                    return
                }
            }
            if error == nil && !isComplete {
                self.receiveLoop(id: id, store: store, gateBox: gateBox, onEvent: onEvent)
            } else {
                entry.conn.cancel()
                self.sessions.removeValue(forKey: id)
            }
        }
    }

    private func route(
        _ msg: FrameProtocol.Message,
        store: CaptureFrameStore,
        gateBox: CaptureStartGateBox,
        onEvent: @escaping @Sendable (Event) -> Void
    ) {
        switch msg.type {
        case .frame:
            let now = ProcessInfo.processInfo.systemUptime
            if let accepted = gateBox.receiveFrame(msg.payload, at: now) {
                for payload in accepted.payloads {
                    if let saved = store.append(payload) {
                        onEvent(.frameStored(sessionID: accepted.sessionID, index: saved.index, thumbnail: saved.thumbnail))
                    }
                }
            }
        case .control:
            let text = String(data: msg.payload, encoding: .utf8) ?? ""
            if text == "started" {
                store.reset()
                let started = gateBox.startBroadcast(at: ProcessInfo.processInfo.systemUptime)
                onEvent(.started(sessionID: started.sessionID, readyAt: started.readyAt))
            } else {
                if text.hasPrefix("finished") {
                    gateBox.finishBroadcast()
                }
                onEvent(.control(text))
            }
        }
    }
}
