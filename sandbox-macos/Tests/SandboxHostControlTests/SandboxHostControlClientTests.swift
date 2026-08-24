import Foundation
import SandboxCore
@testable import SandboxHostControl
import XCTest

final class SandboxHostControlClientTests: XCTestCase {
    func testConnectionAuthenticatesRegistersHeartbeatsAndResponds() async throws {
        let transport = RecordingControlTransport(inboundMode: .validCommand)
        let heartbeat = FixedHeartbeatSource()
        let handler = RecordingMessageHandler()
        let client = SandboxHostControlClient(
            configuration: try configuration(),
            heartbeatSource: heartbeat,
            messageHandler: handler,
            transportFactory: { transport }
        )

        do {
            try await client.runSingleConnection()
            XCTFail("connection unexpectedly completed")
        } catch SandboxHostControlTransportError.disconnected {
        }

        let connectedRequest = await transport.connectedRequest()
        let request = try XCTUnwrap(connectedRequest)
        XCTAssertEqual(
            request.value(
                forHTTPHeaderField: "X-Darkbloom-Sandbox-Host-ID"
            ),
            Self.hostID.uuidString.lowercased()
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer \(Self.token)"
        )
        let handledCount = await handler.handledCount()
        let closeCount = await transport.closeCount()
        XCTAssertEqual(handledCount, 1)
        XCTAssertEqual(closeCount, 1)

        let frames = try await transport.decodedOutboundFrames()
        XCTAssertGreaterThanOrEqual(frames.count, 3)
        XCTAssertEqual(
            frames.map(\.sequence),
            Array(1...UInt64(frames.count))
        )
        XCTAssertEqual(frames.first?.type, .hostRegister)
        XCTAssertTrue(frames.dropFirst().contains { $0.type == .hostHeartbeat })
        XCTAssertTrue(frames.dropFirst().contains { $0.type == .commandState })
        XCTAssertEqual(Set(frames.map(\.connectionEpoch)).count, 1)
    }

    func testConnectionRejectsCoordinatorEpochMismatchBeforeHandler() async throws {
        let transport = RecordingControlTransport(inboundMode: .wrongEpoch)
        let handler = RecordingMessageHandler()
        let client = SandboxHostControlClient(
            configuration: try configuration(),
            heartbeatSource: FixedHeartbeatSource(),
            messageHandler: handler,
            transportFactory: { transport }
        )

        do {
            try await client.runSingleConnection()
            XCTFail("mismatched session was accepted")
        } catch SandboxHostControlTransportError.sessionMismatch {
        }
        let handledCount = await handler.handledCount()
        let closeCount = await transport.closeCount()
        XCTAssertEqual(handledCount, 0)
        XCTAssertEqual(closeCount, 1)
    }

    func testConfigurationRejectsUnsafeCredentialsAndURL() throws {
        let capabilities = Self.capabilities
        XCTAssertThrowsError(
            try SandboxHostControlConfiguration(
                coordinatorURL: URL(string: "https://api.example.test")!,
                hostID: Self.hostID,
                token: Self.token,
                capabilities: capabilities
            )
        )
        XCTAssertThrowsError(
            try SandboxHostControlConfiguration(
                coordinatorURL: URL(
                    string: "wss://user@api.example.test/ws/sandbox-host"
                )!,
                hostID: Self.hostID,
                token: Self.token,
                capabilities: capabilities
            )
        )
        XCTAssertThrowsError(
            try SandboxHostControlConfiguration(
                coordinatorURL: URL(
                    string: "wss://api.example.test/ws/sandbox-host"
                )!,
                hostID: Self.hostID,
                token: "short",
                capabilities: capabilities
            )
        )
    }

    private func configuration() throws -> SandboxHostControlConfiguration {
        try SandboxHostControlConfiguration(
            coordinatorURL: URL(
                string: "wss://api.example.test/ws/sandbox-host"
            )!,
            hostID: Self.hostID,
            token: Self.token,
            capabilities: Self.capabilities,
            heartbeatInterval: .seconds(60)
        )
    }

    private static let hostID = UUID(
        uuidString: "aaaaaaaa-0000-0000-0000-000000000001"
    )!
    private static let token = "sandbox-host-test-token-000000000001"
    private static let capabilities = SandboxWireHostCapabilities(
        daemonVersion: "0.1.0",
        operatingSystem: "macos",
        architecture: "arm64",
        machineModel: "Mac16,1",
        chipName: "Apple M4 Pro",
        cpuCount: 12,
        memoryBytes: 48 * SandboxResourcePolicy.gibibyte,
        maximumSandboxes: 2,
        workspaceSizesBytes: [25 * SandboxResourcePolicy.gibibyte],
        supportsGPU: true
    )
}

private struct FixedHeartbeatSource: SandboxHostHeartbeatSource {
    func heartbeat() async throws -> SandboxWireHostHeartbeat {
        SandboxWireHostHeartbeat(
            mode: "sandbox_dedicated",
            availableCPU: 8,
            availableMemoryBytes: 32 * SandboxResourcePolicy.gibibyte,
            leases: []
        )
    }
}

private actor RecordingMessageHandler: SandboxHostControlMessageHandler {
    private var count = 0

    func handle(
        _ message: SandboxCoordinatorControlMessage
    ) async throws -> SandboxHostControlResponse {
        count += 1
        guard case .command(let envelope) = message else {
            return .none
        }
        return .command(
            SandboxWireCommandStatus(
                commandID: envelope.payload.commandID,
                scope: envelope.payload.scope,
                state: .failed,
                exitCode: 1,
                standardError: "guest agent unavailable",
                errorCode: "guest_agent_unavailable"
            )
        )
    }

    func handledCount() -> Int {
        count
    }
}

private actor RecordingControlTransport: SandboxHostControlTransport {
    enum InboundMode {
        case validCommand
        case wrongEpoch
    }

    struct OutboundFrame {
        let type: SandboxControlMessageType
        let connectionEpoch: UUID
        let sequence: UInt64
    }

    private let inboundMode: InboundMode
    private var request: URLRequest?
    private var outbound: [String] = []
    private var receives = 0
    private var closes = 0

    init(inboundMode: InboundMode) {
        self.inboundMode = inboundMode
    }

    func connect(request: URLRequest) async throws {
        self.request = request
    }

    func send(text: String) async throws {
        outbound.append(text)
    }

    func receiveText() async throws -> String {
        guard receives == 0 else {
            throw SandboxHostControlTransportError.disconnected
        }
        receives += 1
        let registration = try JSONDecoder().decode(
            SandboxControlEnvelope<SandboxWireHostRegister>.self,
            from: Data(try XCTUnwrap(outbound.first).utf8)
        )
        let epoch: UUID
        switch inboundMode {
        case .validCommand:
            epoch = registration.connectionEpoch
        case .wrongEpoch:
            epoch = UUID(
                uuidString: "bbbbbbbb-0000-0000-0000-000000000099"
            )!
        }
        let command = SandboxControlEnvelope(
            type: SandboxControlMessageType.command,
            hostID: registration.hostID,
            connectionEpoch: epoch,
            sequence: 1,
            payload: SandboxWireCommand(
                commandID: UUID(
                    uuidString: "cccccccc-0000-0000-0000-000000000003"
                )!,
                idempotencyKey: "command-1",
                scope: SandboxWireScope(
                    sandboxID: SandboxID(
                        rawValue: UUID(
                            uuidString: "dddddddd-0000-0000-0000-000000000004"
                        )!
                    ),
                    generation: SandboxGeneration(rawValue: 1)!,
                    fencingToken: SandboxFencingToken(rawValue: 1)!
                ),
                arguments: ["/usr/bin/true"],
                timeoutSeconds: 30
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(command), as: UTF8.self)
    }

    func close() async {
        closes += 1
    }

    func connectedRequest() -> URLRequest? {
        request
    }

    func closeCount() -> Int {
        closes
    }

    func decodedOutboundFrames() throws -> [OutboundFrame] {
        try outbound.map { text in
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data(text.utf8)
                ) as? [String: Any]
            )
            return OutboundFrame(
                type: try XCTUnwrap(
                    SandboxControlMessageType(
                        rawValue: try XCTUnwrap(object["type"] as? String)
                    )
                ),
                connectionEpoch: try XCTUnwrap(
                    UUID(
                        uuidString: try XCTUnwrap(
                            object["connection_epoch"] as? String
                        )
                    )
                ),
                sequence: try XCTUnwrap(object["sequence"] as? UInt64)
            )
        }
    }
}
