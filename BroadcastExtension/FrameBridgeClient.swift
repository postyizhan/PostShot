// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Network

/// Extension side of the loopback frame bridge: connects to the main app's listener on
/// 127.0.0.1 and streams length-prefixed messages (`FrameProtocol`).
///
/// Uses a serial queue to preserve frame order and caps in-flight PNG frames so TCP backpressure
/// cannot accumulate unbounded multi-MB payloads inside the extension's ~50 MB memory limit.
final class FrameBridgeClient {
    private let queue = DispatchQueue(label: "com.postshot.bridge.client", qos: .userInitiated)
    private let maxInFlightFrames = 2
    private var connection: NWConnection?
    private var inFlightFrames = 0

    func connect() {
        queue.sync {
            connection?.cancel()
            let conn = NWConnection(
                host: NWEndpoint.Host(FrameBridge.host),
                port: NWEndpoint.Port(rawValue: FrameBridge.port)!,
                using: .tcp
            )
            inFlightFrames = 0
            connection = conn
            conn.start(queue: queue)
        }
    }

    /// Sends one full-resolution PNG keyframe if socket backpressure allows; returns `true` when queued.
    @discardableResult
    func sendFrame(_ png: Data) -> Bool {
        guard let packet = FrameProtocol.encodeIfValid(type: .frame, payload: png) else { return false }
        return queue.sync {
            guard let conn = connection, inFlightFrames < maxInFlightFrames else { return false }
            inFlightFrames += 1
            conn.send(content: packet, completion: .contentProcessed { [weak self] _ in
                self?.inFlightFrames = max(0, (self?.inFlightFrames ?? 1) - 1)
            })
            return true
        }
    }

    /// Sends a control text line (e.g. `"started"`), framed by `FrameProtocol`.
    func sendControl(_ text: String) {
        let packet = FrameProtocol.encodeControl(text)
        queue.async { [weak self] in
            self?.connection?.send(content: packet, completion: .contentProcessed { _ in })
        }
    }

    /// Flushes the final control message and closes the TCP stream cleanly with a short bounded wait.
    func finish(keptCount: Int) {
        let packet = FrameProtocol.encodeControl("finished \(keptCount)")
        let done = DispatchSemaphore(value: 0)
        queue.async { [weak self] in
            guard let self, let conn = self.connection else {
                done.signal()
                return
            }
            conn.send(content: packet, isComplete: true, completion: .contentProcessed { [weak self] _ in
                self?.connection?.cancel()
                self?.connection = nil
                done.signal()
            })
        }
        _ = done.wait(timeout: .now() + .milliseconds(400))
        queue.sync {
            connection?.cancel()
            connection = nil
        }
    }
}
