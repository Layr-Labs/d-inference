import Foundation
import SandboxCore
import XCTest

final class SandboxControlProtocolTests: XCTestCase {
    func testCommandMatchesGoWireContract() throws {
        let envelope = try commandEnvelope()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(envelope)
        let expected = Data(
            """
            {
              "type": "sandbox_command",
              "protocol_version": 1,
              "host_id": "00000000-0000-0000-0000-000000000001",
              "connection_epoch": "00000000-0000-0000-0000-000000000002",
              "sequence": 9,
              "payload": {
                "command_id": "00000000-0000-0000-0000-000000000005",
                "idempotency_key": "command-attempt-1",
                "scope": {
                  "sandbox_id": "00000000-0000-0000-0000-000000000003",
                  "generation": 3,
                  "fencing_token": 7
                },
                "arguments": ["/usr/bin/printf", "hello"],
                "working_directory": "/workspace",
                "timeout_seconds": 900
              }
            }
            """.utf8
        )

        XCTAssertEqual(
            try XCTUnwrap(
                JSONSerialization.jsonObject(with: encoded) as? NSDictionary
            ),
            try XCTUnwrap(
                JSONSerialization.jsonObject(with: expected) as? NSDictionary
            )
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                SandboxControlEnvelope<SandboxWireCommand>.self,
                from: expected
            ),
            envelope
        )
    }

    func testHostRegistrationMatchesCoordinatorFieldNames() throws {
        let envelope = SandboxControlEnvelope(
            type: .hostRegister,
            hostID: try identifier("00000000-0000-0000-0000-000000000001"),
            connectionEpoch: try identifier(
                "00000000-0000-0000-0000-000000000002"
            ),
            sequence: 1,
            payload: SandboxWireHostRegister(
                capabilities: SandboxWireHostCapabilities(
                    daemonVersion: "0.1.0",
                    operatingSystem: "macos",
                    architecture: "arm64",
                    machineModel: "Mac16,1",
                    chipName: "Apple M4 Pro",
                    cpuCount: 12,
                    memoryBytes: 48 * SandboxResourcePolicy.gibibyte,
                    maximumSandboxes: 2,
                    workspaceSizesBytes: [
                        25 * SandboxResourcePolicy.gibibyte,
                        50 * SandboxResourcePolicy.gibibyte,
                    ],
                    supportsGPU: true
                )
            )
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(envelope)
            ) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            [
                "type",
                "protocol_version",
                "host_id",
                "connection_epoch",
                "sequence",
                "payload",
            ]
        )
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        let capabilities = try XCTUnwrap(
            payload["capabilities"] as? [String: Any]
        )
        XCTAssertEqual(
            Set(capabilities.keys),
            [
                "daemon_version",
                "operating_system",
                "architecture",
                "machine_model",
                "chip_name",
                "cpu_count",
                "memory_bytes",
                "maximum_sandboxes",
                "workspace_sizes_bytes",
                "supports_gpu",
            ]
        )
    }

    func testOptionalCommandFieldsAreOmitted() throws {
        var envelope = try commandEnvelope()
        envelope = SandboxControlEnvelope(
            type: envelope.type,
            hostID: envelope.hostID,
            connectionEpoch: envelope.connectionEpoch,
            sequence: envelope.sequence,
            payload: SandboxWireCommand(
                commandID: envelope.payload.commandID,
                idempotencyKey: envelope.payload.idempotencyKey,
                scope: envelope.payload.scope,
                arguments: envelope.payload.arguments,
                timeoutSeconds: envelope.payload.timeoutSeconds
            )
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(envelope)
            ) as? [String: Any]
        )
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        XCTAssertNil(payload["environment"])
        XCTAssertNil(payload["working_directory"])
    }

    func testStrictCodecDecodesCoordinatorCommand() throws {
        let data = try JSONEncoder().encode(commandEnvelope())
        guard case .command(let decoded) =
            try SandboxControlCodec.decodeCoordinatorMessage(data)
        else {
            return XCTFail("expected command message")
        }
        XCTAssertEqual(decoded, try commandEnvelope())
    }

    func testStrictCodecRejectsDuplicateAndUnknownFields() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let valid = try String(
            decoding: encoder.encode(commandEnvelope()),
            as: UTF8.self
        )
        let mutations = [
            valid.replacingOccurrences(
                of: #""sequence":9"#,
                with: #""sequence":9,"sequence":10"#
            ),
            valid.replacingOccurrences(
                of: #""timeout_seconds":900"#,
                with: #""timeout_seconds":900,"\u0074imeout_seconds":1"#
            ),
            valid.replacingOccurrences(
                of: #""sequence":9"#,
                with: #""sequence":9,"auth_token":"forbidden""#
            ),
            valid.replacingOccurrences(
                of: #""fencing_token":7"#,
                with: #""fencing_token":7,"authority":"forbidden""#
            ),
            valid.replacingOccurrences(
                of: #""working_directory":"/workspace""#,
                with: #""environment":null,"working_directory":"/workspace""#
            ),
            valid.replacingOccurrences(
                of: #""working_directory":"/workspace""#,
                with: #""working_directory":"""#
            ),
        ]
        for mutation in mutations {
            XCTAssertThrowsError(
                try SandboxControlCodec.decodeCoordinatorMessage(
                    Data(mutation.utf8)
                ),
                "accepted mutated frame: \(mutation)"
            )
        }
    }

    func testStrictCodecPreservesCaseSensitiveEnvironment() throws {
        let command = try commandEnvelope()
        let withEnvironment = SandboxControlEnvelope(
            type: SandboxControlMessageType.command,
            hostID: command.hostID,
            connectionEpoch: command.connectionEpoch,
            sequence: command.sequence,
            payload: SandboxWireCommand(
                commandID: command.payload.commandID,
                idempotencyKey: command.payload.idempotencyKey,
                scope: command.payload.scope,
                arguments: command.payload.arguments,
                environment: ["FOO": "upper", "foo": "lower"],
                workingDirectory: command.payload.workingDirectory,
                timeoutSeconds: command.payload.timeoutSeconds
            )
        )
        guard case .command(let decoded) =
            try SandboxControlCodec.decodeCoordinatorMessage(
                JSONEncoder().encode(withEnvironment)
            )
        else {
            return XCTFail("expected command")
        }
        XCTAssertEqual(
            decoded.payload.environment,
            ["FOO": "upper", "foo": "lower"]
        )
    }

    func testStrictCodecRejectsDirectionAndLeaseViolations() throws {
        let command = try commandEnvelope()
        let wrongDirection = SandboxControlEnvelope(
            type: SandboxControlMessageType.hostRegister,
            hostID: command.hostID,
            connectionEpoch: command.connectionEpoch,
            sequence: command.sequence,
            payload: command.payload
        )
        XCTAssertThrowsError(
            try SandboxControlCodec.decodeCoordinatorMessage(
                JSONEncoder().encode(wrongDirection)
            )
        )

        let invalidTimeout = SandboxControlEnvelope(
            type: SandboxControlMessageType.command,
            hostID: command.hostID,
            connectionEpoch: command.connectionEpoch,
            sequence: command.sequence,
            payload: SandboxWireCommand(
                commandID: command.payload.commandID,
                idempotencyKey: command.payload.idempotencyKey,
                scope: command.payload.scope,
                arguments: command.payload.arguments,
                workingDirectory: "/workspace",
                timeoutSeconds: 901
            )
        )
        XCTAssertThrowsError(
            try SandboxControlCodec.decodeCoordinatorMessage(
                JSONEncoder().encode(invalidTimeout)
            )
        )

        let zeroSequence = SandboxControlEnvelope(
            type: SandboxControlMessageType.command,
            hostID: command.hostID,
            connectionEpoch: command.connectionEpoch,
            sequence: 0,
            payload: command.payload
        )
        XCTAssertThrowsError(
            try SandboxControlCodec.decodeCoordinatorMessage(
                JSONEncoder().encode(zeroSequence)
            )
        )
    }

    func testStrictCodecBoundsJSONNestingAndRejectsInvalidUTF8() {
        let deeplyNested = Data(
            (
                String(repeating: "[", count: 66)
                    + "0"
                    + String(repeating: "]", count: 66)
            ).utf8
        )
        XCTAssertThrowsError(
            try SandboxControlCodec.decodeCoordinatorMessage(deeplyNested)
        )
        XCTAssertThrowsError(
            try SandboxControlCodec.decodeCoordinatorMessage(Data([0xff]))
        )
    }

    func testCommandStatusAlwaysEncodesOutputTruncation() throws {
        let status = SandboxWireCommandStatus(
            commandID: try identifier(
                "00000000-0000-0000-0000-000000000005"
            ),
            scope: try commandEnvelope().payload.scope,
            state: .running
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(status)
            ) as? [String: Any]
        )
        XCTAssertEqual(object["output_truncated"] as? Bool, false)
        XCTAssertNil(object["stdout"])
        XCTAssertNil(object["stderr"])
    }

    private func commandEnvelope() throws
        -> SandboxControlEnvelope<SandboxWireCommand>
    {
        SandboxControlEnvelope(
            type: .command,
            hostID: try identifier(
                "00000000-0000-0000-0000-000000000001"
            ),
            connectionEpoch: try identifier(
                "00000000-0000-0000-0000-000000000002"
            ),
            sequence: 9,
            payload: SandboxWireCommand(
                commandID: try identifier(
                    "00000000-0000-0000-0000-000000000005"
                ),
                idempotencyKey: "command-attempt-1",
                scope: SandboxWireScope(
                    sandboxID: try XCTUnwrap(
                        SandboxID("00000000-0000-0000-0000-000000000003")
                    ),
                    generation: try XCTUnwrap(
                        SandboxGeneration(rawValue: 3)
                    ),
                    fencingToken: try XCTUnwrap(
                        SandboxFencingToken(rawValue: 7)
                    )
                ),
                arguments: ["/usr/bin/printf", "hello"],
                workingDirectory: "/workspace",
                timeoutSeconds: 900
            )
        )
    }

    private func identifier(_ value: String) throws -> UUID {
        try XCTUnwrap(UUID(uuidString: value))
    }
}
