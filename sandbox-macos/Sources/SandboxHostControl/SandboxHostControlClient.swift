import Foundation
import SandboxCore

public enum SandboxHostControlConfigurationError:
    Error,
    Equatable,
    Sendable
{
    case invalidCoordinatorURL
    case invalidToken
    case invalidHeartbeatInterval
}

public struct SandboxHostControlConfiguration: Sendable {
    public let coordinatorURL: URL
    public let hostID: UUID
    public let token: String
    public let capabilities: SandboxWireHostCapabilities
    public let heartbeatInterval: Duration

    public init(
        coordinatorURL: URL,
        hostID: UUID,
        token: String,
        capabilities: SandboxWireHostCapabilities,
        heartbeatInterval: Duration = .seconds(20)
    ) throws {
        guard let scheme = coordinatorURL.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss",
              coordinatorURL.host != nil,
              coordinatorURL.user == nil,
              coordinatorURL.password == nil,
              coordinatorURL.query == nil,
              coordinatorURL.fragment == nil
        else {
            throw SandboxHostControlConfigurationError.invalidCoordinatorURL
        }
        guard (32...256).contains(token.utf8.count),
              token.trimmingCharacters(in: .whitespacesAndNewlines) == token,
              !token.contains(where: { $0.isWhitespace })
        else {
            throw SandboxHostControlConfigurationError.invalidToken
        }
        guard heartbeatInterval > .zero else {
            throw SandboxHostControlConfigurationError.invalidHeartbeatInterval
        }
        self.coordinatorURL = coordinatorURL
        self.hostID = hostID
        self.token = token
        self.capabilities = capabilities
        self.heartbeatInterval = heartbeatInterval
    }

    var request: URLRequest {
        var request = URLRequest(url: coordinatorURL)
        request.setValue(
            hostID.uuidString.lowercased(),
            forHTTPHeaderField: "X-Darkbloom-Sandbox-Host-ID"
        )
        request.setValue(
            "Bearer \(token)",
            forHTTPHeaderField: "Authorization"
        )
        return request
    }
}

public protocol SandboxHostHeartbeatSource: Sendable {
    func heartbeat() async throws -> SandboxWireHostHeartbeat
}

public protocol SandboxHostControlMessageHandler: Sendable {
    func handle(
        _ message: SandboxCoordinatorControlMessage
    ) async throws -> SandboxHostControlResponse
}

public enum SandboxHostControlResponse: Sendable {
    case none
    case operation(SandboxWireOperationStatus)
    case command(SandboxWireCommandStatus)
    case failure(SandboxWireHostFailure)
}

public actor SandboxHostControlClient {
    public typealias TransportFactory =
        @Sendable () -> any SandboxHostControlTransport

    private let configuration: SandboxHostControlConfiguration
    private let heartbeatSource: any SandboxHostHeartbeatSource
    private let messageHandler: any SandboxHostControlMessageHandler
    private let transportFactory: TransportFactory
    private let encoder: JSONEncoder

    private var transport: (any SandboxHostControlTransport)?
    private var connectionEpoch = UUID()
    private var nextSequence: UInt64 = 1
    private var lastInboundSequence: UInt64 = 0

    public init(
        configuration: SandboxHostControlConfiguration,
        heartbeatSource: any SandboxHostHeartbeatSource,
        messageHandler: any SandboxHostControlMessageHandler,
        transportFactory: @escaping TransportFactory = {
            URLSessionSandboxHostControlTransport()
        }
    ) {
        self.configuration = configuration
        self.heartbeatSource = heartbeatSource
        self.messageHandler = messageHandler
        self.transportFactory = transportFactory
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    public func run() async throws {
        var retryDelay = Duration.seconds(1)
        while !Task.isCancelled {
            do {
                try await runSingleConnection()
                retryDelay = .seconds(1)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try await Task.sleep(for: retryDelay)
                retryDelay = min(retryDelay * 2, .seconds(30))
            }
        }
    }

    package func runSingleConnection() async throws {
        let transport = transportFactory()
        self.transport = transport
        connectionEpoch = UUID()
        nextSequence = 1
        lastInboundSequence = 0
        try await transport.connect(request: configuration.request)
        do {
            try await send(
                type: .hostRegister,
                payload: SandboxWireHostRegister(
                    capabilities: configuration.capabilities
                )
            )

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await self.receiveLoop(transport: transport)
                }
                group.addTask {
                    try await self.heartbeatLoop()
                }
                _ = try await group.next()
                group.cancelAll()
            }
            self.transport = nil
            await transport.close()
        } catch {
            self.transport = nil
            await transport.close()
            throw error
        }
    }

    private func receiveLoop(
        transport: any SandboxHostControlTransport
    ) async throws {
        while !Task.isCancelled {
            let text = try await transport.receiveText()
            guard let data = text.data(using: .utf8) else {
                throw SandboxHostControlTransportError.invalidTextFrame
            }
            let message = try SandboxControlCodec.decodeCoordinatorMessage(data)
            try acceptInbound(message)
            let response = try await messageHandler.handle(message)
            try await send(response)
        }
    }

    private func heartbeatLoop() async throws {
        while !Task.isCancelled {
            try await send(
                type: .hostHeartbeat,
                payload: heartbeatSource.heartbeat()
            )
            try await Task.sleep(for: configuration.heartbeatInterval)
        }
    }

    private func send(_ response: SandboxHostControlResponse) async throws {
        switch response {
        case .none:
            return
        case .operation(let payload):
            try await send(type: .operationState, payload: payload)
        case .command(let payload):
            try await send(type: .commandState, payload: payload)
        case .failure(let payload):
            try await send(type: .hostFailure, payload: payload)
        }
    }

    private func acceptInbound(
        _ message: SandboxCoordinatorControlMessage
    ) throws {
        let identity: (hostID: UUID, connectionEpoch: UUID, sequence: UInt64)
        switch message {
        case .prepare(let envelope):
            identity = (
                envelope.hostID,
                envelope.connectionEpoch,
                envelope.sequence
            )
        case .leaseRenew(let envelope):
            identity = (
                envelope.hostID,
                envelope.connectionEpoch,
                envelope.sequence
            )
        case .command(let envelope):
            identity = (
                envelope.hostID,
                envelope.connectionEpoch,
                envelope.sequence
            )
        case .cancelCommand(let envelope):
            identity = (
                envelope.hostID,
                envelope.connectionEpoch,
                envelope.sequence
            )
        case .stop(let envelope):
            identity = (
                envelope.hostID,
                envelope.connectionEpoch,
                envelope.sequence
            )
        case .delete(let envelope):
            identity = (
                envelope.hostID,
                envelope.connectionEpoch,
                envelope.sequence
            )
        case .drain(let envelope):
            identity = (
                envelope.hostID,
                envelope.connectionEpoch,
                envelope.sequence
            )
        }
        guard identity.hostID == configuration.hostID,
              identity.connectionEpoch == connectionEpoch
        else {
            throw SandboxHostControlTransportError.sessionMismatch
        }
        guard identity.sequence > lastInboundSequence else {
            throw SandboxHostControlTransportError.sequenceReplay
        }
        lastInboundSequence = identity.sequence
    }

    private func send<Payload>(
        type: SandboxControlMessageType,
        payload: Payload
    ) async throws where Payload: Codable & Equatable & Sendable {
        guard let transport else {
            throw SandboxHostControlTransportError.disconnected
        }
        let envelope = SandboxControlEnvelope(
            type: type,
            hostID: configuration.hostID,
            connectionEpoch: connectionEpoch,
            sequence: nextSequence,
            payload: payload
        )
        nextSequence += 1
        let encoded = try encoder.encode(envelope)
        guard let text = String(data: encoded, encoding: .utf8) else {
            throw SandboxHostControlTransportError.invalidTextFrame
        }
        try await transport.send(text: text)
    }
}
