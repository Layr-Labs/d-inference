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

public enum SandboxHostControlClientError: Error, Equatable, Sendable {
    case alreadyRunning
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
        heartbeatInterval: Duration = .seconds(20),
        allowInsecureLoopback: Bool = false
    ) throws {
        guard let scheme = coordinatorURL.scheme?.lowercased(),
              let host = coordinatorURL.host?.lowercased(),
              scheme == "wss"
                || (
                    scheme == "ws"
                        && allowInsecureLoopback
                        && ["localhost", "127.0.0.1", "::1"].contains(host)
                ),
              coordinatorURL.path == "/ws/sandbox-host",
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

public struct SandboxHostControlAdmission: Sendable {
    private let completion:
        @Sendable () async throws -> SandboxHostControlResponse

    public init(
        completion:
            @escaping @Sendable () async throws -> SandboxHostControlResponse
    ) {
        self.completion = completion
    }

    public init(response: SandboxHostControlResponse) {
        self.init { response }
    }

    public func complete() async throws -> SandboxHostControlResponse {
        try await completion()
    }
}

public protocol SandboxHostControlMessageHandler: Sendable {
    func admit(
        _ message: SandboxCoordinatorControlMessage
    ) async throws -> SandboxHostControlAdmission
}

public extension SandboxHostControlMessageHandler {
    func handle(
        _ message: SandboxCoordinatorControlMessage
    ) async throws -> SandboxHostControlResponse {
        try await admit(message).complete()
    }
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
    private var activeRunID: UUID?

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
    }

    public func run() async throws {
        let runID = try beginRun()
        defer { finishRun(runID) }
        var retryDelaySeconds = 1
        let clock = ContinuousClock()
        while !Task.isCancelled {
            let connectedAt = clock.now
            do {
                try await runConnection()
                retryDelaySeconds = 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if connectedAt.duration(to: clock.now) >= .seconds(60) {
                    retryDelaySeconds = 1
                }
                let minimumJitter = Int64(retryDelaySeconds * 800)
                let maximumJitter = Int64(retryDelaySeconds * 1_200)
                let jitterMilliseconds = Int64.random(
                    in: minimumJitter...maximumJitter
                )
                try await Task.sleep(
                    for: .milliseconds(jitterMilliseconds)
                )
                retryDelaySeconds = min(retryDelaySeconds * 2, 30)
            }
        }
    }

    package func runSingleConnection() async throws {
        let runID = try beginRun()
        defer { finishRun(runID) }
        try await runConnection()
    }

    private func beginRun() throws -> UUID {
        guard activeRunID == nil else {
            throw SandboxHostControlClientError.alreadyRunning
        }
        let runID = UUID()
        activeRunID = runID
        return runID
    }

    private func finishRun(_ runID: UUID) {
        if activeRunID == runID {
            activeRunID = nil
        }
    }

    private func runConnection() async throws {
        let transport = transportFactory()
        let connectionEpoch = UUID()
        let writer = SandboxHostOutboundWriter(
            transport: transport,
            hostID: configuration.hostID,
            connectionEpoch: connectionEpoch
        )
        let inboundAuthority = SandboxHostInboundAuthority(
            hostID: configuration.hostID,
            connectionEpoch: connectionEpoch
        )
        let handlerWork = SandboxHostHandlerWorkSet()

        try await withTaskCancellationHandler {
            do {
                try await transport.connect(request: configuration.request)
                try await writer.send(
                    type: .hostRegister,
                    payload: SandboxWireHostRegister(
                        capabilities: configuration.capabilities
                    )
                )
                try await runConnectedTasks(
                    transport: transport,
                    writer: writer,
                    inboundAuthority: inboundAuthority,
                    handlerWork: handlerWork
                )
                await handlerWork.cancelAll()
                await writer.close()
            } catch {
                await handlerWork.cancelAll()
                await writer.close()
                throw error
            }
        } onCancel: {
            Task {
                await handlerWork.cancelAll()
                await writer.close()
            }
        }
    }

    private func runConnectedTasks(
        transport: any SandboxHostControlTransport,
        writer: SandboxHostOutboundWriter,
        inboundAuthority: SandboxHostInboundAuthority,
        handlerWork: SandboxHostHandlerWorkSet
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.receiveLoop(
                    transport: transport,
                    writer: writer,
                    inboundAuthority: inboundAuthority,
                    handlerWork: handlerWork
                )
            }
            group.addTask {
                try await self.heartbeatLoop(
                    transport: transport,
                    writer: writer
                )
            }
            do {
                _ = try await group.next()
                group.cancelAll()
                await writer.close()
                try await group.waitForAll()
            } catch {
                group.cancelAll()
                await writer.close()
                throw error
            }
        }
    }

    private func receiveLoop(
        transport: any SandboxHostControlTransport,
        writer: SandboxHostOutboundWriter,
        inboundAuthority: SandboxHostInboundAuthority,
        handlerWork: SandboxHostHandlerWorkSet
    ) async throws {
        while !Task.isCancelled {
            let text = try await transport.receiveText()
            guard let data = text.data(using: .utf8) else {
                throw SandboxHostControlTransportError.invalidTextFrame
            }
            let message = try SandboxControlCodec.decodeCoordinatorMessage(data)
            try await inboundAuthority.accept(message)
            let handler = messageHandler
            let admission = try await handler.admit(message)
            await handlerWork.submit {
                do {
                    let response = try await admission.complete()
                    try await writer.send(response)
                } catch is CancellationError {
                } catch {
                    await writer.close()
                }
            }
        }
    }

    private func heartbeatLoop(
        transport: any SandboxHostControlTransport,
        writer: SandboxHostOutboundWriter
    ) async throws {
        while !Task.isCancelled {
            try await writer.send(
                type: .hostHeartbeat,
                payload: heartbeatSource.heartbeat()
            )
            try await transport.ping()
            try await Task.sleep(for: configuration.heartbeatInterval)
        }
    }
}
