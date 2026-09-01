import Foundation
import XCTest

@testable import SandboxGuestProtocol

final class SandboxGuestFrameTests: XCTestCase {
    func testRoundTripsEveryFrameKind() throws {
        for kind in SandboxGuestFrameKind.allCases {
            let frame = SandboxGuestFrame(
                kind: kind,
                payload: Data("payload for \(kind)".utf8)
            )
            var buffer = try SandboxGuestFrameCodec.encode(frame)
            let decoded = try SandboxGuestFrameCodec.decode(from: &buffer)
            XCTAssertEqual(decoded, frame)
            XCTAssertTrue(buffer.isEmpty, "decode must consume the frame")
        }
    }

    func testEmptyPayloadIsLegal() throws {
        let frame = SandboxGuestFrame(kind: .handshake, payload: Data())
        var buffer = try SandboxGuestFrameCodec.encode(frame)
        XCTAssertEqual(buffer.count, SandboxGuestFrameCodec.headerBytes)
        XCTAssertEqual(try SandboxGuestFrameCodec.decode(from: &buffer), frame)
    }

    func testPartialBufferYieldsNilWithoutConsuming() throws {
        let frame = SandboxGuestFrame(
            kind: .commandResult,
            payload: Data(repeating: 0x41, count: 512)
        )
        let encoded = try SandboxGuestFrameCodec.encode(frame)

        // Every prefix short of the whole frame must decode to nil and leave
        // the buffer untouched, so a streaming reader can simply append.
        for length in 0..<encoded.count {
            var partial = Data(encoded.prefix(length))
            XCTAssertNil(try SandboxGuestFrameCodec.decode(from: &partial))
            XCTAssertEqual(partial.count, length)
        }

        var complete = encoded
        XCTAssertEqual(
            try SandboxGuestFrameCodec.decode(from: &complete),
            frame
        )
    }

    func testDecodesFramesBackToBackFromOneBuffer() throws {
        let first = SandboxGuestFrame(kind: .handshake, payload: Data("a".utf8))
        let second = SandboxGuestFrame(
            kind: .commandRequest,
            payload: Data("bb".utf8)
        )
        var buffer = try SandboxGuestFrameCodec.encode(first)
        buffer.append(try SandboxGuestFrameCodec.encode(second))

        XCTAssertEqual(try SandboxGuestFrameCodec.decode(from: &buffer), first)
        XCTAssertEqual(try SandboxGuestFrameCodec.decode(from: &buffer), second)
        XCTAssertNil(try SandboxGuestFrameCodec.decode(from: &buffer))
        XCTAssertTrue(buffer.isEmpty)
    }

    func testRejectsUnknownKind() {
        var buffer = Data([0xFF, 0, 0, 0, 0])
        XCTAssertThrowsError(
            try SandboxGuestFrameCodec.decode(from: &buffer)
        ) { error in
            XCTAssertEqual(
                error as? SandboxGuestProtocolError,
                .unknownKind(0xFF)
            )
        }
    }

    func testRejectsOversizedLengthBeforeBuffering() {
        let oversized = UInt32(SandboxGuestFrameCodec.maximumPayloadBytes + 1)
        var buffer = Data([SandboxGuestFrameKind.commandResult.rawValue])
        buffer.append(UInt8(truncatingIfNeeded: oversized >> 24))
        buffer.append(UInt8(truncatingIfNeeded: oversized >> 16))
        buffer.append(UInt8(truncatingIfNeeded: oversized >> 8))
        buffer.append(UInt8(truncatingIfNeeded: oversized))

        // Only the header is present: the cap must be enforced on the declared
        // length, never after reading the payload.
        XCTAssertThrowsError(
            try SandboxGuestFrameCodec.decode(from: &buffer)
        ) { error in
            XCTAssertEqual(
                error as? SandboxGuestProtocolError,
                .payloadTooLarge(Int(oversized))
            )
        }
    }

    func testRefusesToEncodeOversizedPayload() {
        let frame = SandboxGuestFrame(
            kind: .commandResult,
            payload: Data(
                repeating: 0,
                count: SandboxGuestFrameCodec.maximumPayloadBytes + 1
            )
        )
        XCTAssertThrowsError(try SandboxGuestFrameCodec.encode(frame))
    }

    func testMaximumPayloadCoversLargestLegalEnvelope() {
        // Two base64-encoded 1 MiB streams plus envelope overhead must fit.
        let base64PerStream = ((SandboxGuestLimits.maximumStreamBytes + 2) / 3) * 4
        XCTAssertGreaterThan(
            SandboxGuestFrameCodec.maximumPayloadBytes,
            2 * base64PerStream + 1_024
        )
    }
}
