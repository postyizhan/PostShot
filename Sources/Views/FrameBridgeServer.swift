// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import ImageIO
import Network
import UIKit

/// Main-app side of the loopback frame bridge: a TCP listener on 127.0.0.1 that receives
/// length-prefixed `FrameProtocol` messages from the broadcast extension on a serial queue.
@MainActor
final class FrameBridgeServer: ObservableObject {
    struct CapturedPreview: Identifiable {
        let id = UUID()
        let thumbnail: UIImage
    }

    @Published private(set) var status = "未启动"
    @Published private(set) var receivedFrames: [Data] = []
    @Published private(set) var previews: [CapturedPreview] = []
    @Published private(set) var lastControl = "(无)"
    @Published private(set) var isFinished = false

    var frameCount: Int { receivedFrames.count }

    private let transport = Transport()

    func start() {
        transport.start(
            onState: { [weak self] text in
                Task { @MainActor in self?.status = text }
            },
            onConnected: { [weak self] in
                Task { @MainActor in
                    self?.status = "扩展已连接 ✅"
                    self?.isFinished = false
                }
            },
            onMessage: { [weak self] message, thumbnail in
                Task { @MainActor in self?.handle(message: message, thumbnail: thumbnail) }
            }
        )
    }

    func stop() {
        transport.stop()
    }

    /// Clears collected frames for a fresh recording (keeps the listener running).
    func reset() {
        receivedFrames.removeAll()
        previews.removeAll()
        lastControl = "(无)"
        isFinished = false
    }

    private func handle(message: FrameProtocol.Message, thumbnail: UIImage?) {
        switch message.type {
        case .frame:
            receivedFrames.append(message.payload)
            if let thumbnail {
                previews.append(CapturedPreview(thumbnail: thumbnail))
            }
        case .control:
            let raw = String(data: message.payload, encoding: .utf8) ?? ""
            if raw == "started" {
                lastControl = "录制进行中"
            } else if raw.hasPrefix("finished") {
                let parts = raw.split(separator: " ")
                let countText = parts.count > 1 ? String(parts[1]) : "\(receivedFrames.count)"
                lastControl = "已完成（发送 \(countText) 帧）"
                isFinished = true
            } else {
                lastControl = raw.isEmpty ? "(空)" : raw
            }
        }
    }

    nonisolated fileprivate static func makePreviewThumbnail(from png: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 240,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cg)
    }
}

/// Serial-queue-isolated socket listener and per-connection decoder state so `NWConnection`
/// (which gained `Sendable` only in iOS 17) never crosses `@MainActor` boundaries on iOS 16.
private final class Transport: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.postshot.bridge.server", qos: .userInitiated)
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: (conn: NWConnection, decoder: FrameProtocol.Decoder)] = [:]

    func start(
        onState: @escaping @Sendable (String) -> Void,
        onConnected: @escaping @Sendable () -> Void,
        onMessage: @escaping @Sendable (FrameProtocol.Message, UIImage?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, self.listener == nil else { return }
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
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
                    self?.accept(conn, onState: onState, onConnected: onConnected, onMessage: onMessage)
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
        onState: @escaping @Sendable (String) -> Void,
        onConnected: @escaping @Sendable () -> Void,
        onMessage: @escaping @Sendable (FrameProtocol.Message, UIImage?) -> Void
    ) {
        let id = ObjectIdentifier(conn)
        sessions[id] = (conn, FrameProtocol.Decoder())
        onConnected()
        conn.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.sessions.removeValue(forKey: id) }
            if case .cancelled = state { self?.sessions.removeValue(forKey: id) }
        }
        conn.start(queue: queue)
        receiveLoop(id: id, onState: onState, onMessage: onMessage)
    }

    private func receiveLoop(
        id: ObjectIdentifier,
        onState: @escaping @Sendable (String) -> Void,
        onMessage: @escaping @Sendable (FrameProtocol.Message, UIImage?) -> Void
    ) {
        guard let conn = sessions[id]?.conn else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, let entry = self.sessions[id] else { return }
            if let data, !data.isEmpty {
                do {
                    for msg in try entry.decoder.push(data) {
                        let thumb = msg.type == .frame ? FrameBridgeServer.makePreviewThumbnail(from: msg.payload) : nil
                        onMessage(msg, thumb)
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
                self.receiveLoop(id: id, onState: onState, onMessage: onMessage)
            } else {
                entry.conn.cancel()
                self.sessions.removeValue(forKey: id)
            }
        }
    }
}
