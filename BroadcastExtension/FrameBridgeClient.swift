// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Network

/// Extension side of the loopback frame bridge: connects to the main app's listener on
/// 127.0.0.1 and streams length-prefixed messages (`FrameProtocol`). Kept frames are sent as PNG
/// payloads; lifecycle notes ("finished N") as control text. Fire-and-forget — the sample handler
/// must never block on the socket.
final class FrameBridgeClient {
    private var connection: NWConnection?

    func connect() {
        let conn = NWConnection(
            host: NWEndpoint.Host(FrameBridge.host),
            port: NWEndpoint.Port(rawValue: FrameBridge.port)!,
            using: .tcp
        )
        connection = conn
        conn.start(queue: .global(qos: .userInitiated))
    }

    /// Sends one full-resolution PNG keyframe, framed by `FrameProtocol`. Fire-and-forget.
    func sendFrame(_ png: Data) {
        send(FrameProtocol.encode(type: .frame, payload: png))
    }

    /// Sends a control text line (e.g. "finished 12"), framed by `FrameProtocol`.
    func sendControl(_ text: String) {
        send(FrameProtocol.encodeControl(text))
    }

    func close() {
        connection?.cancel()
        connection = nil
    }

    private func send(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }
}
