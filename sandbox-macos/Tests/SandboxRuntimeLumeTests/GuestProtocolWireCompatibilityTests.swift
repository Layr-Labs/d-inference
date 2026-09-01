import Foundation
import SandboxGuestProtocol
import XCTest

@testable import SandboxRuntimeLume

/// The transport is changing; the result format deliberately is not.
///
/// `LumeGuestCommandJournal` persists raw envelope bytes and re-validates them
/// through `LumeGuestCommandResultDecoder` on both write and read. If the agent
/// emitted a different envelope, stored results from before the change would
/// stop replaying. These tests pin the agent's output to the decoder that
/// already exists, so the two cannot drift apart silently.
final class GuestProtocolWireCompatibilityTests: XCTestCase {
    private func decodeThroughHost(
        _ envelope: SandboxGuestResultEnvelope
    ) throws -> SandboxGuestCommandResult {
        try LumeGuestCommandResultDecoder.decode(
            JSONEncoder().encode(envelope)
        )
    }

    func testAgentEnvelopeDecodesThroughTheExistingHostDecoder() throws {
        let envelope = SandboxGuestResultEnvelope(
            exitCode: 0,
            standardOutput: Data("hello".utf8),
            standardError: Data("oops".utf8),
            standardOutputTruncated: false,
            standardErrorTruncated: false,
            timedOut: false
        )
        let decoded = try decodeThroughHost(envelope)

        XCTAssertEqual(decoded.exitCode, 0)
        XCTAssertEqual(decoded.standardOutput, Data("hello".utf8))
        XCTAssertEqual(decoded.standardError, Data("oops".utf8))
        XCTAssertFalse(decoded.standardOutputTruncated)
        XCTAssertFalse(decoded.standardErrorTruncated)
        XCTAssertFalse(decoded.timedOut)
    }

    func testAgentTimeoutEnvelopeDecodesThroughTheExistingHostDecoder() throws {
        let envelope = SandboxGuestResultEnvelope(
            exitCode: 124,
            standardOutput: Data(),
            standardError: Data(),
            standardOutputTruncated: false,
            standardErrorTruncated: false,
            timedOut: true
        )
        let decoded = try decodeThroughHost(envelope)
        XCTAssertTrue(decoded.timedOut)
        XCTAssertEqual(decoded.exitCode, 124)
    }

    func testAgentTruncationFlagsSurviveTheHostDecoder() throws {
        let envelope = SandboxGuestResultEnvelope(
            exitCode: 1,
            standardOutput: Data(repeating: 0xAB, count: 4_096),
            standardError: Data(repeating: 0xCD, count: 8),
            standardOutputTruncated: true,
            standardErrorTruncated: false,
            timedOut: false
        )
        let decoded = try decodeThroughHost(envelope)
        XCTAssertTrue(decoded.standardOutputTruncated)
        XCTAssertFalse(decoded.standardErrorTruncated)
        XCTAssertEqual(decoded.standardOutput.count, 4_096)
        XCTAssertEqual(decoded.standardError.count, 8)
    }

    func testMaximumStreamEnvelopeStaysInsideBothLimits() throws {
        // A full 1 MiB on each stream is legal, must survive the host decoder,
        // and must still fit inside one protocol frame.
        let full = Data(repeating: 0x5A, count: SandboxGuestLimits.maximumStreamBytes)
        let envelope = SandboxGuestResultEnvelope(
            exitCode: 0,
            standardOutput: full,
            standardError: full,
            standardOutputTruncated: true,
            standardErrorTruncated: true,
            timedOut: false
        )
        let encoded = try JSONEncoder().encode(envelope)

        XCTAssertLessThanOrEqual(
            encoded.count,
            LumeGuestCommandEnvelope.maximumEnvelopeBytes,
            "agent envelope must fit the host's envelope cap"
        )
        XCTAssertLessThanOrEqual(
            encoded.count,
            SandboxGuestFrameCodec.maximumPayloadBytes,
            "agent envelope must fit one protocol frame"
        )

        let decoded = try LumeGuestCommandResultDecoder.decode(encoded)
        XCTAssertEqual(decoded.standardOutput.count, SandboxGuestLimits.maximumStreamBytes)
        XCTAssertEqual(decoded.standardError.count, SandboxGuestLimits.maximumStreamBytes)
    }

    func testProtocolAndHostAgreeOnStreamLimit() {
        XCTAssertEqual(
            SandboxGuestLimits.maximumStreamBytes,
            LumeGuestCommandEnvelope.maximumStreamBytes,
            "the agent and the host must cap streams identically"
        )
    }

    func testProtocolAndHostAgreeOnSchemaVersion() {
        XCTAssertEqual(
            SandboxGuestResultEnvelope.schemaVersion,
            LumeGuestCommandEnvelope.schemaVersion
        )
        XCTAssertEqual(
            SandboxGuestResultEnvelope.magic,
            LumeGuestCommandEnvelope.magic
        )
    }
}
