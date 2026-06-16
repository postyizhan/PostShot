// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Length-prefixed binary framing for the loopback bridge (Phase 1).
///
/// The Phase-0 smoke test sent newline-delimited TEXT, which cannot carry PNG bytes — binary
/// payloads contain `0x0A` and every other byte value, so there is no safe delimiter. This protocol
/// frames each message as a fixed header followed by an exact-length payload, so the receiver can
/// reassemble messages from an arbitrarily-chunked TCP byte stream.
///
/// Wire format per message:
/// ```
/// [1 byte: type][4 bytes: payload length, big-endian UInt32][payload bytes...]
/// ```
/// Pure and allocation-light: the encoder builds one `Data`, the `Decoder` buffers partial bytes
/// and emits whole messages. Fully unit-testable without sockets (the one CI-verifiable new logic
/// this phase adds).
enum FrameProtocol {

    /// Message kind. Kept as a raw `UInt8` so unknown future types fail loudly rather than silently.
    enum MessageType: UInt8 {
        case frame = 0x01    // payload is full-resolution PNG bytes for one kept keyframe
        case control = 0x02  // payload is UTF-8 control text (e.g. "finished 12")
    }

    /// A fully-decoded message.
    struct Message: Equatable {
        let type: MessageType
        let payload: Data
    }

    /// Header size in bytes: 1 type + 4 length.
    static let headerSize = 5

    /// Safety cap on a single payload (16 MiB). A full-resolution PNG screenshot is well under this;
    /// a larger declared length means a desync or hostile sender, so we reject rather than allocate.
    static let maxPayloadSize: UInt32 = 16 * 1024 * 1024

    // MARK: - Encoding

    /// Encodes one message into a self-delimiting byte blob ready for `NWConnection.send`.
    static func encode(type: MessageType, payload: Data) -> Data {
        var out = Data(capacity: headerSize + payload.count)
        out.append(type.rawValue)
        var lengthBE = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &lengthBE) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    /// Convenience: encode a control text line.
    static func encodeControl(_ text: String) -> Data {
        encode(type: .control, payload: Data(text.utf8))
    }

    // MARK: - Decoding

    /// Reasons a stream cannot be decoded. Surfaced so the receiver can reset rather than hang.
    enum DecodeError: Error, Equatable {
        case unknownType(UInt8)
        case payloadTooLarge(UInt32)
    }

    /// Incremental decoder over a chunked byte stream.
    ///
    /// Feed it whatever bytes arrive (`push`), get back zero or more complete `Message`s. Partial
    /// headers/payloads are buffered until the rest arrives. Not thread-safe; drive it from one
    /// queue (the connection's receive callback).
    final class Decoder {
        private var buffer = Data()

        /// Appends bytes and returns every complete message now available.
        /// - Throws: `DecodeError` if the stream declares an unknown type or an oversized payload;
        ///   the caller should treat that as fatal for the connection (drop it).
        func push(_ bytes: Data) throws -> [Message] {
            buffer.append(bytes)
            var messages: [Message] = []

            while true {
                guard buffer.count >= headerSize else { break }

                let typeByte = buffer[buffer.startIndex]
                guard let type = MessageType(rawValue: typeByte) else {
                    throw DecodeError.unknownType(typeByte)
                }

                let length = readLength(at: buffer.startIndex + 1)
                guard length <= maxPayloadSize else {
                    throw DecodeError.payloadTooLarge(length)
                }

                let total = headerSize + Int(length)
                guard buffer.count >= total else { break } // payload not fully arrived yet

                let payloadStart = buffer.startIndex + headerSize
                let payload = buffer.subdata(in: payloadStart..<(payloadStart + Int(length)))
                messages.append(Message(type: type, payload: payload))

                buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + total))
            }

            return messages
        }

        /// Drops any buffered partial bytes (e.g. after an error or on reconnect).
        func reset() {
            buffer.removeAll(keepingCapacity: false)
        }

        /// Reads a big-endian UInt32 at an absolute index, independent of `Data`'s slice offset.
        private func readLength(at index: Data.Index) -> UInt32 {
            var value: UInt32 = 0
            for offset in 0..<4 {
                value = (value << 8) | UInt32(buffer[index + offset])
            }
            return value
        }
    }
}
