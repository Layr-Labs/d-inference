import Foundation
import InferenceWorkerProtocol
import Security

public struct InferenceWorkerProcessIdentity: Sendable, Equatable {
    public let launchIdentifier: String
    public let processPublicKey: Data
    public let processIdentifier: Int32
    public let workerBinarySHA256: String?
    public let metallibSHA256: String?
    public let runtimeCapabilitiesJSON: Data
}

public enum InferenceWorkerClientError: Error, Sendable {
    case connectionFailed
    case peerRejected
    case handshakeFailed
    case identityDidNotRotate
    case notCertified
    case rejected(InferenceWorkerErrorCode)
    case invalidFrame
    case invalidated
}
private final class XPCReplyBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Value, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
private final class XPCRemoteBox: @unchecked Sendable {
    let value: any InferenceWorkerXPCProtocol
    init(_ value: any InferenceWorkerXPCProtocol) { self.value = value }
}


public final class WorkerFrameDelivery: @unchecked Sendable {
    public let frame: WorkerResponseFrame
    private let lock = NSLock()
    private var acknowledgement: (@Sendable () async -> Void)?

    init(frame: WorkerResponseFrame, acknowledgement: @escaping @Sendable () async -> Void) {
        self.frame = frame
        self.acknowledgement = acknowledgement
    }

    public func acknowledgeAfterForwarding() async {
        let acknowledgement = takeAcknowledgement()
        await acknowledgement?()
    }

    private func takeAcknowledgement() -> (@Sendable () async -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        let result = acknowledgement
        acknowledgement = nil
        return result
    }
}


private final class WorkerHostReceiver: NSObject, InferenceWorkerHostProtocol, @unchecked Sendable {
    private let frameHandler: @Sendable (WorkerResponseFrame) -> Void
    private let eventHandler: @Sendable (WorkerEvent) -> Void

    init(frameHandler: @escaping @Sendable (WorkerResponseFrame) -> Void,
         eventHandler: @escaping @Sendable (WorkerEvent) -> Void) {
        self.frameHandler = frameHandler
        self.eventHandler = eventHandler
    }

    func workerDidEmit(_ frame: WorkerResponseFrame) { frameHandler(frame) }
    func workerDidEmitEvent(_ event: WorkerEvent) { eventHandler(event) }
}

/// Supervisor-side ciphertext transport. It owns no process private key and
/// never decodes a request body or encrypted response payload.
public actor InferenceWorkerClient {
    public typealias ConnectionFactory = @Sendable () -> NSXPCConnection

    private let connectionFactory: ConnectionFactory
    private var connection: NSXPCConnection?
    private var remote: (any InferenceWorkerXPCProtocol)?
    private var receiver: WorkerHostReceiver?
    private var identity: InferenceWorkerProcessIdentity?
    private var lastInvalidatedIdentity: InferenceWorkerProcessIdentity?
    private var certifiedLaunchIdentifier: String?
    private var frameContinuations: [
        String: AsyncThrowingStream<WorkerFrameDelivery, Error>.Continuation
    ] = [:]
    private var pendingRPCFailures: [
        UUID: @Sendable (Error) -> Void
    ] = [:]
    private var invalidationGeneration: UInt64 = 0
    private var invalidationHandler:
        (@Sendable (InferenceWorkerProcessIdentity?) -> Void)?

    public init(connectionFactory: @escaping ConnectionFactory = {
        NSXPCConnection(serviceName: InferenceWorkerContract.machServiceName)
    }) {
        self.connectionFactory = connectionFactory
    }
    public func setInvalidationHandler(
        _ handler: (@Sendable (InferenceWorkerProcessIdentity?) -> Void)?
    ) {
        invalidationHandler = handler
    }


    public func connect() async throws -> InferenceWorkerProcessIdentity {
        if let identity, remote != nil { return identity }
        let connection = connectionFactory()
        let receiver = WorkerHostReceiver(
            frameHandler: { [weak self] frame in
                Task { await self?.receive(frame) }
            },
            eventHandler: { _ in })
        connection.remoteObjectInterface = InferenceWorkerXPCInterfaces.worker()
        connection.exportedInterface = InferenceWorkerXPCInterfaces.host()
        connection.exportedObject = receiver
        invalidationGeneration &+= 1
        let generation = invalidationGeneration
        connection.invalidationHandler = { [weak self] in
            Task { await self?.connectionInvalidated(generation: generation) }
        }
        connection.interruptionHandler = { [weak self] in
            Task { await self?.connectionInvalidated(generation: generation) }
        }
        connection.resume()

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({
            [weak connection] _ in connection?.invalidate()
        }) as? InferenceWorkerXPCProtocol else {
            connection.invalidate()
            throw InferenceWorkerClientError.connectionFailed
        }
        let challenge = Self.randomChallenge()
        guard let request = WorkerHandshakeRequest(challenge: challenge) else {
            connection.invalidate()
            throw InferenceWorkerClientError.handshakeFailed
        }
        let proxyBox = XPCRemoteBox(proxy)
        let response: WorkerHandshakeResponse = try await awaitReply { finish in
            proxyBox.value.handshake(request) { response, rawError in
                guard rawError == InferenceWorkerErrorCode.none.rawValue,
                      let response else {
                    finish(.failure(InferenceWorkerClientError.handshakeFailed))
                    return
                }
                finish(.success(response))
            }
         }
        do {
            try InferenceWorkerPeerIdentity.validate(connection: connection, expected: .worker)
        } catch {
            connection.invalidate()
            throw InferenceWorkerClientError.peerRejected
        }
        guard response.challenge == challenge,
              response.processPublicKey.count == 32 else {
            connection.invalidate()
            throw InferenceWorkerClientError.handshakeFailed
        }
        let newIdentity = InferenceWorkerProcessIdentity(
            launchIdentifier: response.launchIdentifier,
            processPublicKey: response.processPublicKey,
            processIdentifier: response.processIdentifier,
            workerBinarySHA256: response.workerBinarySHA256,
            metallibSHA256: response.metallibSHA256,
            runtimeCapabilitiesJSON:
                response.runtimeCapabilitiesJSON)
        if let previous = lastInvalidatedIdentity,
           previous.processIdentifier != newIdentity.processIdentifier,
           previous.processPublicKey == newIdentity.processPublicKey {
            connection.invalidate()
            throw InferenceWorkerClientError.identityDidNotRotate
        }

        self.connection = connection
        self.remote = proxy
        self.receiver = receiver
        self.identity = newIdentity
        self.certifiedLaunchIdentifier = nil
        return newIdentity
    }

    public func configure(
        _ configuration: WorkerBootstrapConfiguration
    ) async throws -> WorkerBootstrapResult {
        let identity = try await connect()
        guard let remote else {
            throw InferenceWorkerClientError.connectionFailed
        }
        let remoteBox = XPCRemoteBox(remote)
        let result: WorkerBootstrapResult = try await awaitReply { finish in
        remoteBox.value.configure(configuration) { result, code in
            guard code == InferenceWorkerErrorCode.none.rawValue,
                  let result else {
                finish(.failure(InferenceWorkerClientError.rejected(
                    InferenceWorkerErrorCode(rawValue: code)
                        ?? .execution)))
                return
            }
            finish(.success(result))
        }
                 }
        certifiedLaunchIdentifier = nil
        _ = identity
        return result
    }

    public func markCertified(
        launchIdentifier: String,
        connectionGeneration: UInt64
    ) async throws {
        guard identity?.launchIdentifier == launchIdentifier,
              let remote else {
            throw InferenceWorkerClientError.notCertified
        }
        let remoteBox = XPCRemoteBox(remote)
        let code: Int = try await awaitReply { finish in
            remoteBox.value.certify(
                launchIdentifier: launchIdentifier,
                connectionGeneration: connectionGeneration) {
                    finish(.success($0))
                }
         }
        guard code == InferenceWorkerErrorCode.none.rawValue else {
            throw InferenceWorkerClientError.notCertified
        }
        certifiedLaunchIdentifier = launchIdentifier
    }

    public func answerCodeChallenge(
        _ request: WorkerCodeChallengeRequest
    ) async throws -> WorkerCodeChallengeProof {
        guard certifiedLaunchIdentifier == identity?.launchIdentifier,
              let remote else { throw InferenceWorkerClientError.notCertified }
        let remoteBox = XPCRemoteBox(remote)
        return try await awaitReply { finish in
            remoteBox.value.answerCodeChallenge(request) { proof, code in
                guard code == InferenceWorkerErrorCode.none.rawValue, let proof else {
                    finish(.failure(InferenceWorkerClientError.rejected(
                        InferenceWorkerErrorCode(rawValue: code) ?? .invalidRequest)))
                    return
                }
                finish(.success(proof))
            }
         }
    }

    public func invalidateCertification() {
        certifiedLaunchIdentifier = nil
    }

    public func currentIdentity() -> InferenceWorkerProcessIdentity? { identity }

    public func submit(_ request: WorkerInferenceRequest) async throws
        -> AsyncThrowingStream<WorkerFrameDelivery, Error> {
        _ = try await connect()
        guard certifiedLaunchIdentifier == identity?.launchIdentifier else {
            throw InferenceWorkerClientError.notCertified
        }
        guard let remote else { throw InferenceWorkerClientError.connectionFailed }
        let stream = AsyncThrowingStream<WorkerFrameDelivery, Error>(
            bufferingPolicy: .bufferingOldest(InferenceWorkerContract.acknowledgementWindow)
        ) { continuation in
            frameContinuations[request.requestIdentifier] = continuation
            continuation.onTermination = { @Sendable [weak self] reason in
                guard case .cancelled = reason else { return }
                Task { await self?.cancel(requestIdentifier: request.requestIdentifier) }
            }
        }
        let remoteBox = XPCRemoteBox(remote)
        let code: Int = try await awaitReply { finish in
            remoteBox.value.begin(request) { finish(.success($0)) }
         }
        guard code == InferenceWorkerErrorCode.none.rawValue else {
            frameContinuations.removeValue(forKey: request.requestIdentifier)?.finish(
                throwing: InferenceWorkerClientError.rejected(
                    InferenceWorkerErrorCode(rawValue: code) ?? .execution))
            throw InferenceWorkerClientError.rejected(
                InferenceWorkerErrorCode(rawValue: code) ?? .execution)
        }
        return stream
    }

    public func cancel(requestIdentifier: String) {
        remote?.cancel(requestIdentifier: requestIdentifier)
    }

    public func preloadModel(identifier: String) async throws {
        _ = try await connect()
        guard certifiedLaunchIdentifier == identity?.launchIdentifier else {
            throw InferenceWorkerClientError.notCertified
        }
        guard let remote else { throw InferenceWorkerClientError.connectionFailed }
        let remoteBox = XPCRemoteBox(remote)
        let code: Int = try await awaitReply { finish in
            remoteBox.value.preloadModel(identifier: identifier) {
                finish(.success($0))
            }
         }
        guard code == InferenceWorkerErrorCode.none.rawValue else {
            throw InferenceWorkerClientError.rejected(
                InferenceWorkerErrorCode(rawValue: code) ?? .execution)
        }
    }

    public func capacitySnapshot() async throws -> WorkerCapacitySnapshot {
        _ = try await connect()
        guard let remote else { throw InferenceWorkerClientError.connectionFailed }
        let remoteBox = XPCRemoteBox(remote)
        return try await awaitReply { finish in
            remoteBox.value.capacitySnapshot { snapshot, code in
                guard code == InferenceWorkerErrorCode.none.rawValue, let snapshot else {
                    finish(.failure(InferenceWorkerClientError.rejected(
                        InferenceWorkerErrorCode(rawValue: code) ?? .execution)))
                    return
                }
                finish(.success(snapshot))
            }
         }
    }

    public func shutdown() {
        connection?.invalidate()
        connection = nil
        remote = nil
        receiver = nil
        invalidateOutstanding(with: InferenceWorkerClientError.invalidated)
    }

    private func receive(_ frame: WorkerResponseFrame) {
        guard let continuation = frameContinuations[frame.requestIdentifier],
              let acknowledgement = WorkerFrameAcknowledgement(
                requestIdentifier: frame.requestIdentifier, sequence: frame.sequence) else { return }
        let delivery = WorkerFrameDelivery(frame: frame) { [weak self] in
            await self?.acknowledge(acknowledgement)
        }
        let result = continuation.yield(delivery)
        if case .dropped = result {
            connection?.invalidate()
            return
        }
        if frame.terminal {
            frameContinuations.removeValue(forKey: frame.requestIdentifier)?.finish()
        }
    }

    private func acknowledge(_ acknowledgement: WorkerFrameAcknowledgement) {
        remote?.acknowledge(acknowledgement)
    }

    private func connectionInvalidated(generation: UInt64) {
        guard generation == invalidationGeneration else { return }
        let invalidatedIdentity = identity
        if let invalidatedIdentity { lastInvalidatedIdentity = invalidatedIdentity }
        connection = nil
        remote = nil
        receiver = nil
        identity = nil
        certifiedLaunchIdentifier = nil
        invalidateOutstanding(with: InferenceWorkerClientError.invalidated)
        invalidationHandler?(invalidatedIdentity)
    }

    private func invalidateOutstanding(with error: Error) {
        let continuations = frameContinuations.values
        frameContinuations.removeAll()
        for continuation in continuations { continuation.finish(throwing: error) }
        let failures = pendingRPCFailures.values
        pendingRPCFailures.removeAll()
        for fail in failures { fail(error) }
    }

    private func awaitReply<Value: Sendable>(
        _ operation: @escaping @Sendable (
            @escaping @Sendable (Result<Value, Error>) -> Void
        ) -> Void
    ) async throws -> Value {
        let identifier = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            let box = XPCReplyBox<Value>(continuation)
            pendingRPCFailures[identifier] = { error in
                box.resume(.failure(error))
            }
            operation { [weak self] result in
                box.resume(result)
                Task { await self?.rpcFinished(identifier) }
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                await self?.rpcTimedOut(identifier, box: box)
            }
        }
    }

    private func rpcFinished(_ identifier: UUID) {
        pendingRPCFailures.removeValue(forKey: identifier)
    }

    private func rpcTimedOut<Value>(
        _ identifier: UUID,
        box: XPCReplyBox<Value>
    ) {
        guard pendingRPCFailures.removeValue(forKey: identifier) != nil else {
            return
        }
        box.resume(.failure(InferenceWorkerClientError.connectionFailed))
    }

    private static func randomChallenge() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess)
        return Data(bytes)
    }
}
