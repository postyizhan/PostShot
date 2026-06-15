// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Network

/// Main-app side of the loopback frame bridge: a TCP listener on 127.0.0.1 that the broadcast
/// extension connects to. For the Phase-0 smoke test it just receives newline-delimited text
/// messages and surfaces them, proving the extension→app channel works without an App Group.
@MainActor
final class FrameBridgeServer: ObservableObject {
    @Published private(set) var status = "未启动"
    @Published private(set) var messageCount = 0
    @Published private(set) var lastMessage = "(无)"

    private var listener: NWListener?
    private var connections: [NWConnection] = []

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: FrameBridge.port)!)
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready: self?.status = "监听中(127.0.0.1:\(FrameBridge.port))"
                    case .failed(let e): self?.status = "监听失败:\(e.localizedDescription)"
                    case .cancelled: self?.status = "已停止"
                    default: break
                    }
                }
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

    private func accept(_ conn: NWConnection) {
        connections.append(conn)
        conn.start(queue: .global(qos: .userInitiated))
        receive(on: conn)
        Task { @MainActor in self.status = "扩展已连接 ✅" }
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                Task { @MainActor in
                    self?.messageCount += 1
                    self?.lastMessage = text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            if error == nil && !isComplete {
                Task { @MainActor in self?.receive(on: conn) }
            }
        }
    }
}
