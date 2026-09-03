import Foundation
import XCTest

@testable import SandboxGuestProtocol

final class SandboxGuestMessageTests: XCTestCase {
    func testResultEnvelopeEncodesTheBootstrapWireKeys() throws {
        let envelope = SandboxGuestResultEnvelope(
            exitCode: 0,
            standardOutput: Data("out".utf8),
            standardError: Data("err".utf8),
            standardOutputTruncated: false,
            standardErrorTruncated: false,
            timedOut: false
        )
        let encoded = try JSONEncoder().encode(envelope)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        // The launchd/SSH path's decoder reads exactly these keys. Any drift
        // here silently breaks journal replay of stored envelopes.
        XCTAssertEqual(
            Set(object.keys),
            [
                "magic",
                "schema_version",
                "exit_code",
                "stdout_length",
                "stderr_length",
                "stdout_truncated",
                "stderr_truncated",
                "timed_out",
                "stdout_base64",
                "stderr_base64",
            ]
        )
        XCTAssertEqual(object["magic"] as? String, "darkbloom_guest_result")
        XCTAssertEqual(object["schema_version"] as? Int, 2)
        XCTAssertEqual(object["stdout_base64"] as? String, "b3V0")
        XCTAssertEqual(object["stderr_base64"] as? String, "ZXJy")
        XCTAssertEqual(object["stdout_length"] as? Int, 3)
        XCTAssertEqual(object["stderr_length"] as? Int, 3)
    }

    func testResultEnvelopeRoundTrips() throws {
        let envelope = SandboxGuestResultEnvelope(
            exitCode: 124,
            standardOutput: Data(repeating: 0xAB, count: 1_000),
            standardError: Data(),
            standardOutputTruncated: true,
            standardErrorTruncated: false,
            timedOut: true
        )
        let decoded = try JSONDecoder().decode(
            SandboxGuestResultEnvelope.self,
            from: JSONEncoder().encode(envelope)
        )
        XCTAssertEqual(decoded, envelope)
        XCTAssertTrue(decoded.isSelfConsistent)
    }

    func testSelfConsistencyMirrorsHostInvariants() {
        let timedOutWithWrongCode = SandboxGuestResultEnvelope(
            exitCode: 0,
            standardOutput: Data(),
            standardError: Data(),
            standardOutputTruncated: false,
            standardErrorTruncated: false,
            timedOut: true
        )
        XCTAssertFalse(
            timedOutWithWrongCode.isSelfConsistent,
            "timed out must imply exit code 124"
        )

        let outOfRange = SandboxGuestResultEnvelope(
            exitCode: 256,
            standardOutput: Data(),
            standardError: Data(),
            standardOutputTruncated: false,
            standardErrorTruncated: false,
            timedOut: false
        )
        XCTAssertFalse(outOfRange.isSelfConsistent)

        let legal = SandboxGuestResultEnvelope(
            exitCode: 124,
            standardOutput: Data(),
            standardError: Data(),
            standardOutputTruncated: false,
            standardErrorTruncated: false,
            timedOut: true
        )
        XCTAssertTrue(legal.isSelfConsistent)
    }

    /// The executor flag rides the handshake so the host can route on a fact.
    ///
    /// It is deliberately *not* part of acceptance: an agent that refuses
    /// commands is still the agent this host provisioned, and rejecting its
    /// handshake would throw away the identity proof along with it.
    func testHandshakeCarriesTheAgentsExecutorState() throws {
        let serving = SandboxGuestHandshake(
            agentVersion: "0.1.0",
            imageID: "base-2026-09",
            executionEnabled: true
        )
        let wire = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(serving)
        ) as? [String: Any]
        XCTAssertEqual(wire?["execution_enabled"] as? Bool, true)

        // Refusing is the default, so a caller that forgets cannot accidentally
        // advertise an executor it does not have.
        XCTAssertFalse(
            SandboxGuestHandshake(agentVersion: "0.1.0", imageID: "i")
                .executionEnabled
        )

        // Neither value changes whether the peer is trusted.
        XCTAssertTrue(serving.isAcceptable(expectedImageID: "base-2026-09"))
        XCTAssertTrue(
            SandboxGuestHandshake(
                agentVersion: "0.1.0",
                imageID: "base-2026-09",
                executionEnabled: false
            ).isAcceptable(expectedImageID: "base-2026-09")
        )
    }

    /// An agent baked before the field existed still handshakes, and is read as
    /// refusing -- which is what such an agent does.
    func testHandshakeFromAnOlderAgentDecodesAsRefusing() throws {
        let legacyWire = Data(
            #"{"magic":"darkbloom_guest_agent","protocol_version":1,"#
            .appending(#""agent_version":"0.1.0","image_id":"x-1"}"#).utf8
        )
        let decoded = try JSONDecoder().decode(
            SandboxGuestHandshake.self, from: legacyWire
        )
        XCTAssertTrue(decoded.isAcceptable(expectedImageID: "x-1"))
        XCTAssertFalse(decoded.executionEnabled)
    }

    func testHandshakeAcceptanceChecksMagicVersionAndImage() {
        let handshake = SandboxGuestHandshake(
            agentVersion: "0.1.0",
            imageID: "base-2026-09"
        )
        XCTAssertTrue(handshake.isAcceptable(expectedImageID: nil))
        XCTAssertTrue(handshake.isAcceptable(expectedImageID: "base-2026-09"))
        XCTAssertFalse(handshake.isAcceptable(expectedImageID: "other"))

        let wrongMagic = SandboxGuestHandshake(
            magic: "not-darkbloom",
            agentVersion: "0.1.0",
            imageID: "base-2026-09"
        )
        XCTAssertFalse(wrongMagic.isAcceptable(expectedImageID: nil))

        let wrongVersion = SandboxGuestHandshake(
            protocolVersion: 99,
            agentVersion: "0.1.0",
            imageID: "base-2026-09"
        )
        XCTAssertFalse(wrongVersion.isAcceptable(expectedImageID: nil))

        let noAgentVersion = SandboxGuestHandshake(
            agentVersion: "",
            imageID: "base-2026-09"
        )
        XCTAssertFalse(noAgentVersion.isAcceptable(expectedImageID: nil))
    }

    func testCommandWireRejectsMalformedRequests() {
        func wire(
            executable: String = "/bin/echo",
            arguments: [String] = [],
            environment: [String: String] = [:],
            workingDirectory: String = "/Users/lume",
            timeoutSeconds: UInt32 = 60,
            idempotencyKey: String = "key"
        ) -> SandboxGuestCommandWire {
            SandboxGuestCommandWire(
                idempotencyKey: idempotencyKey,
                executable: executable,
                arguments: arguments,
                environment: environment,
                workingDirectory: workingDirectory,
                timeoutSeconds: timeoutSeconds
            )
        }

        XCTAssertTrue(wire().isWellFormed)
        XCTAssertFalse(wire(executable: "echo").isWellFormed)
        XCTAssertFalse(wire(executable: "/bin/e\0cho").isWellFormed)
        XCTAssertFalse(wire(workingDirectory: "relative").isWellFormed)
        XCTAssertFalse(wire(timeoutSeconds: 0).isWellFormed)
        XCTAssertFalse(wire(timeoutSeconds: 901).isWellFormed)
        XCTAssertFalse(wire(idempotencyKey: "").isWellFormed)
        XCTAssertFalse(
            wire(environment: ["BAD=KEY": "value"]).isWellFormed
        )
        XCTAssertFalse(
            wire(
                arguments: Array(
                    repeating: "a",
                    count: SandboxGuestLimits.maximumArgumentCount + 1
                )
            ).isWellFormed
        )
    }

    func testCommandWireRoundTrips() throws {
        let wire = SandboxGuestCommandWire(
            idempotencyKey: UUID().uuidString,
            executable: "/bin/echo",
            arguments: ["hello", "world"],
            environment: ["USER_DEFINED": "1"],
            workingDirectory: "/Users/lume",
            timeoutSeconds: 30
        )
        let decoded = try JSONDecoder().decode(
            SandboxGuestCommandWire.self,
            from: JSONEncoder().encode(wire)
        )
        XCTAssertEqual(decoded, wire)
        XCTAssertTrue(decoded.isWellFormed)
    }
}
