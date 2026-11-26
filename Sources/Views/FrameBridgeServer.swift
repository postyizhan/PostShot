// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Network
import UIKit

/// Main-app side of the loopback frame bridge: receives length-prefixed `FrameProtocol` messages
/// from the broadcast extension and streams frame payloads directly into `CaptureFrameStore` on
/// disk so dense captures never bloat app RAM.
@MainActor
final class FrameBridgeServer: ObservableObject {
    struct CapturedPreview: Identifiable {
        let id = UUID()
        let poolIndex: Int
        let thumbnail: UIImage
    }

    let frameStore = CaptureFrameStore()

    @Published private(set) var status = "未启动"
    @Published private(set) var previews: [CapturedPreview] = []
    @Published private(set) var lastControl = "(无)"
    @Published private(set) var isFinished = false

    var frameCount: Int { previews.count }

    private let transport = Transport()

    func start() {
        let store = frameStore
        transport.start(
            store: store,
            onState: { [weak self] text in
                Task { @MainActor in self?.status = text }
            },
            onConnected: { [weak self] in
                Task { @MainActor in
                    self?.status = "扩展已连接 ✅"
                    self?.isFinished = false
                }
            },
            onFrameStored: { [weak self] index, thumbnail in
                Task { @MainActor in
                    self?.previews.append(CapturedPreview(poolIndex: index, thumbnail: thumbnail))
                }
            },
            onControl: { [weak self] text in
                Task { @MainActor in self?.handleControl(text) }
            }
        )
    }

    func stop() {
        transport.stop()
    }

    /// Clears collected frames and disk files for a fresh recording (keeps listener running).
    func reset() {
        frameStore.reset()
        previews.removeAll()
        lastControl = "(无)"
        isFinished = false
    }

    private func handleControl(_ raw: String) {
        if raw == "started" {
            lastControl = "录制进行中"
        } else if raw.hasPrefix("finished") {
            let parts = raw.split(separator: " ")
            let countText = parts.count > 1 ? String(parts[1]) : "\(previews.count)"
            lastControl = "已完成（采集 \(countText) 帧）"
            isFinished = true
        } else {
            lastControl = raw.isEmpty ? "(空)" : raw
        }
    }
}

/// Serial-queue-isolated socket listener and per-connection decoder state so `NWConnection`
/// never crosses `@MainActor` boundaries on iOS 16.
private final class Transport: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.postshot.bridge.server", qos: .userInitiated)
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: (conn: NWConnection, decoder: FrameProtocol.Decoder)] = [:]

    func start(
        store: CaptureFrameStore,
        onState: @escaping @Sendable (String) -> Void,
        onConnected: @escaping @Sendable () -> Void,
        onFrameStored: @escaping @Sendable (Int, UIImage) -> Void,
        onControl: @escaping @Sendable (String) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, self.listener == nil else { return }
            do {
                let params = NWParameters.tcp
                params.acceptLocalOnly = true
                let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: FrameBridge.port)!)
                self.listener = listener
                onState("启动中…")
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: onState("监听中 (127.0.0.1:\(FrameBridge.port))")
                    case .failed(let err): onState("监听失败：\(err.localizedDescription)")
                    case .cancelled: onState("已停止")
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] conn in
                    self?.accept(
                        conn, store: store, onState: onState,
                        onConnected: onConnected, onFrameStored: onFrameStored, onControl: onControl
                    )
                }
                listener.start(queue: self.queue)
            } catch {
                onState("无法创建监听：\(error.localizedDescription)")
            }
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

    private func accept(
        _ conn: NWConnection,
        store: CaptureFrameStore,
        onState: @escaping @Sendable (String) -> Void,
        onConnected: @escaping @Sendable () -> Void,
        onFrameStored: @escaping @Sendable (Int, UIImage) -> Void,
        onControl: @escaping @Sendable (String) -> Void
    ) {
        let id = ObjectIdentifier(conn)
        sessions[id] = (conn, FrameProtocol.Decoder())
        onConnected()
        conn.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.sessions.removeValue(forKey: id) }
            if case .cancelled = state { self?.sessions.removeValue(forKey: id) }
        }
        conn.start(queue: queue)
        receiveLoop(id: id, store: store, onState: onState, onFrameStored: onFrameStored, onControl: onControl)
    }

    private func receiveLoop(
        id: ObjectIdentifier,
        store: CaptureFrameStore,
        onState: @escaping @Sendable (String) -> Void,
        onFrameStored: @escaping @Sendable (Int, UIImage) -> Void,
        onControl: @escaping @Sendable (String) -> Void
    ) {
        guard let conn = sessions[id]?.conn else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, let entry = self.sessions[id] else { return }
            if let data, !data.isEmpty {
                do {
                    for msg in try entry.decoder.push(data) {
                        switch msg.type {
                        case .frame:
                            if let saved = store.append(msg.payload) {
                                onFrameStored(saved.index, saved.thumbnail)
                            }
                        case .control:
                            onControl(String(data: msg.payload, encoding: .utf8) ?? "")
                        }
                    }
                } catch {
                    entry.decoder.reset()
                    entry.conn.cancel()
                    self.sessions.removeValue(forKey: id)
                    onState("协议解码错误，连接已重置")
                    return
                }
            }
            if error == nil && !isComplete {
                self.receiveLoop(
                    id: id, store: store, onState: onState,
                    onFrameStored: onFrameStored, onControl: onControl
                )
            } else {
                entry.conn.cancel()
                self.sessions.removeValue(forKey: id)
            }
        }
    }
}
