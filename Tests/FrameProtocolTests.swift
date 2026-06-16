// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import PostShot

/// Validates `FrameProtocol` framing/reassembly over an arbitrarily-chunked byte stream.
/// Pure logic, no sockets — the one CI-verifiable new piece of Phase 1.
final class FrameProtocolTests: XCTestCase {

    // MARK: - Round trip

    func testEncodeDecodeSingleFrame() throws {
        let payload = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF, 0x0A, 0x0D]) // PNG-ish, incl. newline byte
        let wire = FrameProtocol.encode(type: .frame, payload: payload)

        let decoder = FrameProtocol.Decoder()
        let messages = try decoder.push(wire)

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].type, .frame)
        XCTAssertEqual(messages[0].payload, payload, "Binary payload incl. 0x0A must survive intact")
    }

    func testControlTextRoundTrip() throws {
        let wire = FrameProtocol.encodeControl("finished 12")
        let decoder = FrameProtocol.Decoder()
        let messages = try decoder.push(wire)

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].type, .control)
        XCTAssertEqual(String(data: messages[0].payload, encoding: .utf8), "finished 12")
    }

    // MARK: - Chunking

    func testMessageSplitAcrossManyChunks() throws {
        let payload = Data((0..<1000).map { UInt8($0 & 0xFF) })
        let wire = FrameProtocol.encode(type: .frame, payload: payload)

        let decoder = FrameProtocol.Decoder()
        var collected: [FrameProtocol.Message] = []
        // Feed one byte at a time — the worst-case fragmentation.
        for byte in wire {
            collected += try decoder.push(Data([byte]))
        }

        XCTAssertEqual(collected.count, 1, "Byte-by-byte feed must still yield exactly one message")
        XCTAssertEqual(collected[0].payload, payload)
    }

    func testMultipleMessagesInOneChunk() throws {
        var wire = Data()
        wire.append(FrameProtocol.encode(type: .frame, payload: Data([1, 2, 3])))
        wire.append(FrameProtocol.encodeControl("hello"))
        wire.append(FrameProtocol.encode(type: .frame, payload: Data([9, 8, 7, 6])))

        let decoder = FrameProtocol.Decoder()
        let messages = try decoder.push(wire)

        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0].payload, Data([1, 2, 3]))
        XCTAssertEqual(messages[1].type, .control)
        XCTAssertEqual(messages[2].payload, Data([9, 8, 7, 6]))
    }

    func testPartialMessageHeldUntilComplete() throws {
        let payload = Data([10, 20, 30, 40, 50])
        let wire = FrameProtocol.encode(type: .frame, payload: payload)

        let decoder = FrameProtocol.Decoder()
        // First half: header + part of payload → nothing complete yet.
        let split = FrameProtocol.headerSize + 2
        XCTAssertTrue(try decoder.push(wire.prefix(split)).isEmpty,
                      "Incomplete payload must not emit a message")
        // Remainder completes it.
        let messages = try decoder.push(wire.suffix(from: split))
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].payload, payload)
    }

    func testEmptyPayloadIsValid() throws {
        let wire = FrameProtocol.encode(type: .control, payload: Data())
        let decoder = FrameProtocol.Decoder()
        let messages = try decoder.push(wire)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].payload.count, 0, "Zero-length payload is a valid message")
    }

    // MARK: - Errors

    func testUnknownTypeThrows() {
        var wire = Data([0xEE]) // bogus type
        var lengthBE = UInt32(0).bigEndian
        withUnsafeBytes(of: &lengthBE) { wire.append(contentsOf: $0) }

        let decoder = FrameProtocol.Decoder()
        XCTAssertThrowsError(try decoder.push(wire)) { error in
            XCTAssertEqual(error as? FrameProtocol.DecodeError, .unknownType(0xEE))
        }
    }

    func testOversizedPayloadThrows() {
        var wire = Data([FrameProtocol.MessageType.frame.rawValue])
        var lengthBE = (FrameProtocol.maxPayloadSize + 1).bigEndian
        withUnsafeBytes(of: &lengthBE) { wire.append(contentsOf: $0) }

        let decoder = FrameProtocol.Decoder()
        XCTAssertThrowsError(try decoder.push(wire)) { error in
            XCTAssertEqual(error as? FrameProtocol.DecodeError,
                           .payloadTooLarge(FrameProtocol.maxPayloadSize + 1))
        }
    }
}
