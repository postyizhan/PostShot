// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Network

/// Main-app side of the loopback frame bridge: a TCP listener on 127.0.0.1 that the broadcast
/// extension connects to. Reassembles length-prefixed `FrameProtocol` messages from the byte
/// stream — PNG keyframes are collected into `receivedFrames`; control text updates status.
///
/// Phase 1: receives REAL frames (not the Phase-0 text smoke test). Stitching the collected
/// frames is Phase 2; here we just gather them and let `CaptureView` show thumbnails.
@MainActor
final class FrameBridgeServer: ObservableObject {
    @Published private(set) var status = "未启动"
    @Published private(set) var receivedFrames: [Data] = []   // full-resolution PNG bytes, in order
    @Published private(set) var lastControl = "(无)"
    @Published private(set) var isFinished = false

    var frameCount: Int { receivedFrames.count }

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let decoder = FrameProtocol.Decoder()

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: FrameBridge.port)!)
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.handleListenerState(state) }
            }
            listener.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.accept(conn) }
            }
            listener.start(queue: .global(qos: .userInitiated))
            status = "启动中…"
        } catch {
            status = "无法创建监听:\(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }

    /// Clears collected frames for a fresh recording (keeps the listener running).
    func reset() {
        receivedFrames.removeAll()
        decoder.reset()
        lastControl = "(无)"
        isFinished = false
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready: status = "监听中(127.0.0.1:\(FrameBridge.port))"
        case .failed(let e): status = "监听失败:\(e.localizedDescription)"
        case .cancelled: status = "已停止"
        default: break
        }
    }

    private func accept(_ conn: NWConnection) {
        connections.append(conn)
        conn.start(queue: .global(qos: .userInitiated))
        receive(on: conn)
        status = "扩展已连接 ✅"
        isFinished = false
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                Task { @MainActor in self?.ingest(data) }
            }
            if error == nil && !isComplete {
                Task { @MainActor in self?.receive(on: conn) }
            }
        }
    }

    /// Feeds raw bytes through the protocol decoder and routes each complete message.
    private func ingest(_ bytes: Data) {
        do {
            for message in try decoder.push(bytes) {
                switch message.type {
                case .frame:
                    receivedFrames.append(message.payload)
                case .control:
                    let text = String(data: message.payload, encoding: .utf8) ?? "(非文本)"
                    lastControl = text
                    if text.hasPrefix("finished") { isFinished = true }
                }
            }
        } catch {
            // Stream desync or hostile sender — drop buffered bytes and surface it.
            decoder.reset()
            status = "协议解码错误:\(error)"
        }
    }
}
