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
        XCTAssertThrowsError(
            try SandboxHostControlConfiguration(
                coordinatorURL: URL(
                    string: "ws://api.example.test/ws/sandbox-host"
                )!,
                hostID: Self.hostID,
                token: Self.token,
                capabilities: capabilities,
                allowInsecureLoopback: true
            )
        )
        XCTAssertNoThrow(
            try SandboxHostControlConfiguration(
                coordinatorURL: URL(
                    string: "ws://127.0.0.1/ws/sandbox-host"
                )!,
                hostID: Self.hostID,
                token: Self.token,
                capabilities: capabilities,
                allowInsecureLoopback: true
            )
        )
    }

    func testOutboundWriterPreservesWireOrderAcrossSuspension() async throws {
        let transport = SequencingControlTransport()
        let writer = SandboxHostOutboundWriter(
            transport: transport,
            hostID: Self.hostID,
            connectionEpoch: UUID()
        )
        let first = Task {
            try await writer.send(
                type: SandboxControlMessageType.drain,
                payload: SandboxWireDrain(
                    operationID: UUID(),
                    reason: "first"
                )
            )
        }
        await transport.waitForFirstSend()
        let second = Task {
            try await writer.send(
                type: SandboxControlMessageType.drain,
                payload: SandboxWireDrain(
                    operationID: UUID(),
                    reason: "second"
                )
            )
        }
        while await writer.nextSequenceForTesting() != 3 {
            await Task.yield()
        }
        await transport.releaseFirstSend()
        try await first.value
        try await second.value
        let completedSequences = await transport.completedSequences()
        XCTAssertEqual(completedSequences, [1, 2])
    }

    func testOutboundWriterFitsEscapedCommandOutputToFrameLimit() async throws {
        let transport = CapturingControlTransport()
        let writer = SandboxHostOutboundWriter(
            transport: transport,
            hostID: Self.hostID,
            connectionEpoch: UUID()
        )
        let oversized = String(repeating: "\u{0000}", count: 400_000)
        try await writer.send(
            .command(
                SandboxWireCommandStatus(
                    commandID: UUID(),
                    scope: SandboxWireScope(
                        sandboxID: SandboxID(rawValue: UUID()),
                        generation: SandboxGeneration(rawValue: 1)!,
                        fencingToken: SandboxFencingToken(rawValue: 1)!
                    ),
                    state: .succeeded,
                    exitCode: 0,
                    standardOutput: oversized,
                    standardError: oversized
                )
            )
        )

        let captured = await transport.lastText()
        let text = try XCTUnwrap(captured)
        let encoded = Data(text.utf8)
        XCTAssertLessThanOrEqual(
            encoded.count,
            SandboxControlCodec.maximumFrameBytes
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        XCTAssertEqual(payload["output_truncated"] as? Bool, true)
        XCTAssertLessThan(
            (payload["stdout"] as? String)?.utf8.count ?? 0,
            oversized.utf8.count
        )
        XCTAssertLessThan(
            (payload["stderr"] as? String)?.utf8.count ?? 0,
            oversized.utf8.count
        )
        XCTAssertLessThanOrEqual(
            (payload["stdout"] as? String)?.utf8.count ?? 0,
            SandboxControlCodec.maximumOutputBytes
        )
        XCTAssertLessThanOrEqual(
            (payload["stderr"] as? String)?.utf8.count ?? 0,
            SandboxControlCodec.maximumOutputBytes
        )
    }

    func testOutboundWriterCapsEachOutputBelowFrameLimit() async throws {
        let transport = CapturingControlTransport()
        let writer = SandboxHostOutboundWriter(
            transport: transport,
            hostID: Self.hostID,
            connectionEpoch: UUID()
        )
        let oversized = String(
            repeating: "x",
            count: SandboxControlCodec.maximumOutputBytes + 4_096
        )
        try await writer.send(
            .command(
                SandboxWireCommandStatus(
                    commandID: UUID(),
                    scope: SandboxWireScope(
                        sandboxID: SandboxID(rawValue: UUID()),
                        generation: SandboxGeneration(rawValue: 1)!,
                        fencingToken: SandboxFencingToken(rawValue: 1)!
                    ),
                    state: .succeeded,
                    exitCode: 0,
                    standardOutput: oversized
                )
            )
        )

        let captured = await transport.lastText()
        let encoded = Data(try XCTUnwrap(captured).utf8)
        XCTAssertLessThanOrEqual(
            encoded.count,
            SandboxControlCodec.maximumFrameBytes
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        XCTAssertEqual(payload["output_truncated"] as? Bool, true)
        XCTAssertEqual(
            (payload["stdout"] as? String)?.utf8.count,
            SandboxControlCodec.maximumOutputBytes
        )
    }

    func testCancellationClosesBlockedReceiveAndRejectsConcurrentRun() async throws {
        let transport = BlockingReceiveControlTransport()
        let client = SandboxHostControlClient(
            configuration: try configuration(),
            heartbeatSource: FixedHeartbeatSource(),
            messageHandler: RecordingMessageHandler(),
            transportFactory: { transport }
        )
        let running = Task {
            try await client.runSingleConnection()
        }
        await transport.waitUntilReceiving()
        do {
            try await client.runSingleConnection()
            XCTFail("concurrent run was accepted")
        } catch SandboxHostControlClientError.alreadyRunning {
        }

        running.cancel()
        do {
            try await running.value
            XCTFail("cancelled run completed successfully")
        } catch is CancellationError {
        } catch SandboxHostControlTransportError.disconnected {
        }
        let closeCount = await transport.closeCount()
        XCTAssertEqual(closeCount, 1)
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
        baseImageIDs: ["macos-tahoe-v1"],
        supportsGPU: true
    )
}

private actor SequencingControlTransport: SandboxHostControlTransport {
    private var sends = 0
    private var firstEntered = false
    private var firstEnteredWaiter: CheckedContinuation<Void, Never>?
    private var firstRelease: CheckedContinuation<Void, Never>?
    private var completed: [UInt64] = []

    func connect(request _: URLRequest) async throws {
    }

    func send(text: String) async throws {
        sends += 1
        let sequence = try Self.sequence(in: text)
        if sends == 1 {
            await withCheckedContinuation {
                firstRelease = $0
                firstEntered = true
                firstEnteredWaiter?.resume()
                firstEnteredWaiter = nil
            }
        }
        completed.append(sequence)
    }

    func receiveText() async throws -> String {
        throw SandboxHostControlTransportError.disconnected
    }

    func ping() async throws {
    }

    func close() async {
    }

    func waitForFirstSend() async {
        if firstEntered {
            return
        }
        await withCheckedContinuation {
            firstEnteredWaiter = $0
        }
    }

    func releaseFirstSend() {
        firstRelease?.resume()
        firstRelease = nil
    }

    func completedSequences() -> [UInt64] {
        completed
    }

    private static func sequence(in text: String) throws -> UInt64 {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(text.utf8)
            ) as? [String: Any]
        )
        return try XCTUnwrap(
            (object["sequence"] as? NSNumber)?.uint64Value
        )
    }
}

private actor CapturingControlTransport: SandboxHostControlTransport {
    private var text: String?

    func connect(request _: URLRequest) async throws {
    }

    func send(text: String) async throws {
        self.text = text
    }

    func receiveText() async throws -> String {
        throw SandboxHostControlTransportError.disconnected
    }

    func ping() async throws {
    }

    func close() async {
    }

    func lastText() -> String? {
        text
    }
}

private actor BlockingReceiveControlTransport: SandboxHostControlTransport {
    private var receiveWaiter: CheckedContinuation<String, Error>?
    private var receiving = false
    private var receivingWaiter: CheckedContinuation<Void, Never>?
    private var closes = 0

    func connect(request _: URLRequest) async throws {
    }

    func send(text _: String) async throws {
    }

    func receiveText() async throws -> String {
        try await withCheckedThrowingContinuation {
            receiveWaiter = $0
            receiving = true
            receivingWaiter?.resume()
            receivingWaiter = nil
        }
    }

    func ping() async throws {
    }

    func close() async {
        guard closes == 0 else {
            return
        }
        closes = 1
        receiveWaiter?.resume(
            throwing: SandboxHostControlTransportError.disconnected
        )
        receiveWaiter = nil
    }

    func waitUntilReceiving() async {
        if receiving {
            return
        }
        await withCheckedContinuation {
            receivingWaiter = $0
        }
    }

    func closeCount() -> Int {
        closes
    }
}

private struct FixedHeartbeatSource: SandboxHostHeartbeatSource {
    func heartbeat() async throws -> SandboxWireHostHeartbeat {
        SandboxWireHostHeartbeat(
            mode: "sandbox_dedicated",
            availableCPU: 8,
            availableMemoryBytes: 32 * SandboxResourcePolicy.gibibyte,
            nextFencingToken: 1,
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
    private var responseSeen = false
    private var responseWaiter: CheckedContinuation<String, Error>?

    init(inboundMode: InboundMode) {
        self.inboundMode = inboundMode
    }

    func connect(request: URLRequest) async throws {
        self.request = request
    }

    func send(text: String) async throws {
        outbound.append(text)
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
           object["type"] as? String
                == SandboxControlMessageType.commandState.rawValue
        {
            responseSeen = true
            responseWaiter?.resume(
                throwing: SandboxHostControlTransportError.disconnected
            )
            responseWaiter = nil
        }
    }

    func receiveText() async throws -> String {
        guard receives == 0 else {
            if responseSeen {
                throw SandboxHostControlTransportError.disconnected
            }
            return try await withCheckedThrowingContinuation {
                responseWaiter = $0
            }
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
                idempotencyKey: "00000000-0000-0000-0000-000000000006",
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

    func ping() async throws {
    }

    func close() async {
        closes += 1
        responseWaiter?.resume(
            throwing: SandboxHostControlTransportError.disconnected
        )
        responseWaiter = nil
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
