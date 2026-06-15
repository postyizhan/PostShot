// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Network

/// Extension side of the loopback frame bridge: connects to the main app's listener on
/// 127.0.0.1 and sends newline-delimited text messages. Phase-0 smoke test only — no frame
/// pixels yet, just proving the extension can reach the app process without an App Group.
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

    /// Sends a single newline-terminated text line. Fire-and-forget.
    func send(_ line: String) {
        let payload = Data((line + "\n").utf8)
        connection?.send(content: payload, completion: .contentProcessed { _ in })
    }

    func close() {
        connection?.cancel()
        connection = nil
    }
}
