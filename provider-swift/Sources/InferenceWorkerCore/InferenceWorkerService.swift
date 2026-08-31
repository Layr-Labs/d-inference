import Darwin
import Foundation
import InferenceWorkerProtocol
import ProviderCore

private struct WorkerDeliveryState {
    var pending: [WorkerResponseFrame] = []
    var unacknowledged: [UInt64: Int] = [:]
    var terminalSequence: UInt64?
    var bufferedBytes = 0
    var nextSequence: UInt64 = 0
}
private final class WorkerSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}


private actor InferenceWorkerServiceState {
    let runtime: InferenceWorkerRuntime
    private weak var host: (any InferenceWorkerHostProtocol)?
    private var configured = false
    private var tasks: [String: Task<Void, Never>] = [:]
    private var certifiedConnectionGeneration: UInt64?
    private var deliveries: [String: WorkerDeliveryState] = [:]
    private var requestBytes: [String: Int] = [:]
    private var aggregateRequestBytes = 0
    private var aggregateResponseBytes = 0
    private var acknowledgementWaiters: [
        String: [UInt64: CheckedContinuation<Void, Never>]
    ] = [:]
    private var invalidated = false
    private var configurationMutationInProgress = false
    private var preloadInProgress = false

    init(runtime: InferenceWorkerRuntime) {
        self.runtime = runtime
    }

    func attach(host: any InferenceWorkerHostProtocol) {
        guard !invalidated else { return }
        self.host = host
        host.workerDidEmitEvent(WorkerEvent(code: .launch, value: Int64(ProcessInfo.processInfo.processIdentifier)))
    }

    func configure(
        _ configuration: WorkerBootstrapConfiguration
    ) async -> (WorkerBootstrapResult?, InferenceWorkerErrorCode) {
        guard !invalidated, tasks.isEmpty, deliveries.isEmpty,
              !configurationMutationInProgress, !preloadInProgress else {
            return (nil, invalidated ? .connectionInvalidated : .capacity)
        }
        configurationMutationInProgress = true
        defer { configurationMutationInProgress = false }
        certifiedConnectionGeneration = nil
        configured = false
        do {
            let result = try await runtime.configure(configuration)
            configured = true
            host?.workerDidEmitEvent(WorkerEvent(
                code: .configured,
                value: Int64(result.acceptedModelIdentifiers.count)))
            return (result, .none)
        } catch {
            configured = false
            return (nil, .modelArtifact)
        }
    }

    func certify(
        launchIdentifier: String,
        connectionGeneration: UInt64
    ) -> InferenceWorkerErrorCode {
        guard configured, !invalidated,
              launchIdentifier == runtime.launchID,
              connectionGeneration > 0 else { return .invalidRequest }
        certifiedConnectionGeneration = connectionGeneration
        return .none
    }

    func answerCodeChallenge(
        _ request: WorkerCodeChallengeRequest
    ) async -> (WorkerCodeChallengeProof?, InferenceWorkerErrorCode) {
        guard certifiedConnectionGeneration == request.connectionGeneration,
              request.launchIdentifier == runtime.launchID else {
            return (nil, .notConfigured)
        }
        do {
            return (try await runtime.answerCodeChallenge(request), .none)
        } catch {
            return (nil, .invalidRequest)
        }
    }

    func begin(_ request: WorkerInferenceRequest) -> InferenceWorkerErrorCode {
        guard !invalidated else { return .connectionInvalidated }
        guard configured, certifiedConnectionGeneration != nil else {
            return .notConfigured
        }
        guard tasks.count < InferenceWorkerContract.maximumConcurrentRequests else { return .capacity }
        guard tasks[request.requestIdentifier] == nil, deliveries[request.requestIdentifier] == nil else {
            return .duplicateRequest
        }
        let requestByteCount = request.envelope.count
            + (request.authenticatedMetadataJSON?.count ?? 0)
            + (request.senderPublicKey?.count ?? 0)
        let (newAggregate, overflow) = aggregateRequestBytes.addingReportingOverflow(
            requestByteCount)
        guard !overflow,
              newAggregate <= InferenceWorkerContract.maximumAggregateRequestBytes else {
            return .capacity
        }
        aggregateRequestBytes = newAggregate
        requestBytes[request.requestIdentifier] = requestByteCount
        deliveries[request.requestIdentifier] = WorkerDeliveryState()
        host?.workerDidEmitEvent(WorkerEvent(code: .requestAccepted))
        let identifier = request.requestIdentifier
        let task = Task { [weak self, runtime] in
            guard let self else { return }
            do {
                try await runtime.executeStreaming(request) { frame in
                    try await self.enqueueFrame(
                        frame, requestIdentifier: identifier)
                }
            } catch {
                let mapped = Self.mapExecutionError(error)
                await self.enqueueTerminal(
                    requestIdentifier: identifier,
                    failure: mapped.failure,
                    workerCode: mapped.workerCode)
            }
            await self.taskFinished(identifier)
        }
        tasks[identifier] = task
        return .none
    }

    private static func mapExecutionError(
        _ error: Error
    ) -> (workerCode: InferenceWorkerErrorCode, failure: InferenceFailure) {
        let failure = WorkerInferenceSupport.sanitizedInferenceFailure(
            from: error, phase: .generation)
        let workerCode: InferenceWorkerErrorCode
        switch failure.code {
        case .invalidRequest, .invalidMedia, .mediaTooLarge,
             .unsupportedMedia, .templateRender:
            workerCode = .invalidRequest
        case .modelUnavailable, .capacity:
            workerCode = .capacity
        case .cancelled:
            workerCode = .cancelled
        case .encryptionFailure, .generationFailure, .internalFailure:
            workerCode = .execution
        }
        return (workerCode, failure)
    }

    func acknowledge(_ acknowledgement: WorkerFrameAcknowledgement) {
        guard var delivery = deliveries[acknowledgement.requestIdentifier],
              let acknowledgedBytes = delivery.unacknowledged.removeValue(
                forKey: acknowledgement.sequence) else { return }
        delivery.bufferedBytes = max(0, delivery.bufferedBytes - acknowledgedBytes)
        aggregateResponseBytes = max(0, aggregateResponseBytes - acknowledgedBytes)
        let terminalAcknowledged = delivery.terminalSequence == acknowledgement.sequence
        deliveries[acknowledgement.requestIdentifier] = delivery
        let waiter = acknowledgementWaiters[
            acknowledgement.requestIdentifier
        ]?.removeValue(forKey: acknowledgement.sequence)
        if acknowledgementWaiters[acknowledgement.requestIdentifier]?.isEmpty == true {
            acknowledgementWaiters.removeValue(forKey: acknowledgement.requestIdentifier)
        }
        if terminalAcknowledged {
            deliveries.removeValue(forKey: acknowledgement.requestIdentifier)
            host?.workerDidEmitEvent(WorkerEvent(code: .requestCompleted))
        } else {
            drain(acknowledgement.requestIdentifier)
        }
        waiter?.resume()
    }

    func cancel(_ identifier: String) {
        let task = tasks[identifier]
        let hadRequest = task != nil || deliveries[identifier] != nil
            || acknowledgementWaiters[identifier] != nil
        guard hadRequest else { return }
        task?.cancel()
        if let waiters = acknowledgementWaiters.removeValue(forKey: identifier) {
            for waiter in waiters.values { waiter.resume() }
        }
        host?.workerDidEmitEvent(WorkerEvent(code: .requestCancelled))
    }

    func invalidate() async {
        invalidated = true
        configured = false
        certifiedConnectionGeneration = nil
        for task in tasks.values { task.cancel() }
        let identifiers = Set(deliveries.keys)
            .union(acknowledgementWaiters.keys)
        for identifier in identifiers { abandonDelivery(identifier) }
        tasks.removeAll()
        requestBytes.removeAll()
        aggregateRequestBytes = 0
        aggregateResponseBytes = 0
        host = nil
        await runtime.shutdown()
    }

    func preloadModel(_ identifier: String) async -> InferenceWorkerErrorCode {
        guard configured, !invalidated, tasks.isEmpty,
              !configurationMutationInProgress, !preloadInProgress else {
            return .capacity
        }
        preloadInProgress = true
        defer { preloadInProgress = false }
        do {
            try await runtime.preloadModel(identifier: identifier)
            return .none
        } catch {
            return .modelArtifact
        }
    }

    func capacitySnapshot() async -> WorkerCapacitySnapshot {
        await runtime.capacitySnapshot(
            activeRequests: tasks.count,
            queuedRequests: deliveries.values.reduce(0) { $0 + $1.pending.count })
    }

    private func enqueueFrame(
        _ frame: WorkerResponseFrame,
        requestIdentifier: String
    ) async throws {
        guard var delivery = deliveries[requestIdentifier],
              delivery.terminalSequence == nil,
              frame.requestIdentifier == requestIdentifier,
              frame.sequence == delivery.nextSequence,
              aggregateResponseBytes + frame.payload.count
                <= InferenceWorkerContract.maximumAggregateResponseBytes else {
            enqueueTerminal(
                requestIdentifier: requestIdentifier,
                failure: InferenceFailure(
                    code: .capacity,
                    statusCode: 503,
                    errorReason: .capacityBusy),
                workerCode: .backpressure)
            throw InferenceWorkerRuntimeError.responseTooLarge
        }
        delivery.nextSequence &+= 1
        if frame.terminal { delivery.terminalSequence = frame.sequence }
        delivery.pending.append(frame)
        delivery.bufferedBytes += frame.payload.count
        aggregateResponseBytes += frame.payload.count
        deliveries[requestIdentifier] = delivery
        await withCheckedContinuation { continuation in
            acknowledgementWaiters[requestIdentifier, default: [:]][frame.sequence]
                = continuation
            drain(requestIdentifier)
        }
    }


    private func enqueueTerminal(
        requestIdentifier: String,
        failure: InferenceFailure,
        workerCode: InferenceWorkerErrorCode
    ) {
        guard var delivery = deliveries[requestIdentifier], delivery.terminalSequence == nil else { return }
        let sequence = delivery.nextSequence
        let metadata = WorkerTerminalMetadata(
            cacheReceiptNonce: nil, prefixCacheProtocol: nil,
            lookup: nil, ready: nil, lookupV2: nil, readyV2: nil,
            reasoningTokens: failure.attemptUsage?.reasoningTokens ?? 0,
            errorReason: failure.errorReason,
            terminalCause: failure.terminalCause,
            attemptUsage: failure.attemptUsage)
        guard sequence < UInt64(InferenceWorkerContract.maximumFramesPerRequest),
              let metadataJSON = try? JSONEncoder().encode(metadata),
              let frame = WorkerResponseFrame(
                kind: .terminal, requestIdentifier: requestIdentifier,
                sequence: sequence,
                promptTokens: failure.attemptUsage?.promptTokens ?? 0,
                completionTokens: failure.attemptUsage?.completionTokens ?? 0,
                failureCode: workerCode.rawValue,
                statusCode: failure.statusCode,
                resultMetadataJSON: metadataJSON,
                terminal: true) else { return }
        delivery.nextSequence &+= 1
        delivery.terminalSequence = sequence
        aggregateResponseBytes = max(
            0, aggregateResponseBytes - delivery.pending.reduce(0) { $0 + $1.payload.count })
        delivery.bufferedBytes = delivery.unacknowledged.values.reduce(0, +)
        delivery.pending.removeAll()
        delivery.pending.append(frame)
        delivery.bufferedBytes += frame.payload.count
        aggregateResponseBytes += frame.payload.count
        deliveries[requestIdentifier] = delivery
        drain(requestIdentifier)
    }

    private func drain(_ requestIdentifier: String) {
        guard let host, var delivery = deliveries[requestIdentifier] else { return }
        while delivery.unacknowledged.count < InferenceWorkerContract.acknowledgementWindow,
              !delivery.pending.isEmpty {
            let frame = delivery.pending.removeFirst()
            delivery.unacknowledged[frame.sequence] = frame.payload.count
            host.workerDidEmit(frame)
            if frame.terminal { break }
        }
        deliveries[requestIdentifier] = delivery
    }

    private func abandonDelivery(_ identifier: String) {
        if let delivery = deliveries.removeValue(forKey: identifier) {
            aggregateResponseBytes = max(
                0, aggregateResponseBytes - delivery.bufferedBytes)
        }
        if let waiters = acknowledgementWaiters.removeValue(forKey: identifier) {
            for waiter in waiters.values { waiter.resume() }
        }
    }

    private func releaseRequestAccounting(_ identifier: String) {
        aggregateRequestBytes = max(
            0, aggregateRequestBytes
                - (requestBytes.removeValue(forKey: identifier) ?? 0))
    }

    private func taskFinished(_ identifier: String) {
        tasks.removeValue(forKey: identifier)
        releaseRequestAccounting(identifier)
    }
}

public final class InferenceWorkerService: NSObject, InferenceWorkerXPCProtocol, @unchecked Sendable {
    private let state: InferenceWorkerServiceState

    public init(runtime: InferenceWorkerRuntime) {
        self.state = InferenceWorkerServiceState(runtime: runtime)
    }

    public func attach(host: any InferenceWorkerHostProtocol) {
        let host = WorkerSendableBox(host)
        Task { await state.attach(host: host.value) }
    }

    public func invalidate() {
        Task { await state.invalidate() }
    }

    public func handshake(_ request: WorkerHandshakeRequest, withReply reply: @escaping (WorkerHandshakeResponse?, Int) -> Void) {
        let runtime = state.runtime
        guard request.version == InferenceWorkerContract.version,
              let response = WorkerHandshakeResponse(
                version: InferenceWorkerContract.version,
                challenge: request.challenge,
                launchIdentifier: runtime.launchID,
                processPublicKey: runtime.processPublicKey,
                processIdentifier: ProcessInfo.processInfo.processIdentifier,
                workerBinarySHA256: runtime.workerBinarySHA256,
                metallibSHA256: runtime.metallibSHA256,
                runtimeCapabilitiesJSON:
                    runtime.runtimeCapabilitiesJSON) else {
            reply(nil, InferenceWorkerErrorCode.incompatibleVersion.rawValue)
            return
        }
        reply(response, InferenceWorkerErrorCode.none.rawValue)
    }

    public func configure(
        _ configuration: WorkerBootstrapConfiguration,
        withReply reply:
            @escaping (WorkerBootstrapResult?, Int) -> Void
    ) {
        let reply = WorkerSendableBox(reply)
        Task {
            let result = await state.configure(configuration)
            reply.value(result.0, result.1.rawValue)
        }
    }

    public func certify(
        launchIdentifier: String,
        connectionGeneration: UInt64,
        withReply reply: @escaping (Int) -> Void
    ) {
        let reply = WorkerSendableBox(reply)
        Task {
            let code = await state.certify(
                launchIdentifier: launchIdentifier,
                connectionGeneration: connectionGeneration)
            reply.value(code.rawValue)
        }
    }

    public func answerCodeChallenge(
        _ request: WorkerCodeChallengeRequest,
        withReply reply: @escaping (WorkerCodeChallengeProof?, Int) -> Void
    ) {
        let reply = WorkerSendableBox(reply)
        Task {
            let result = await state.answerCodeChallenge(request)
            reply.value(result.0, result.1.rawValue)
        }
    }

    public func begin(_ request: WorkerInferenceRequest, withReply reply: @escaping (Int) -> Void) {
        let reply = WorkerSendableBox(reply)
        Task { reply.value(await state.begin(request).rawValue) }
    }

    public func acknowledge(_ acknowledgement: WorkerFrameAcknowledgement) {
        Task { await state.acknowledge(acknowledgement) }
    }

    public func cancel(requestIdentifier: String) {
        Task { await state.cancel(requestIdentifier) }
    }

    public func preloadModel(identifier: String, withReply reply: @escaping (Int) -> Void) {
        let reply = WorkerSendableBox(reply)
        Task { reply.value(await state.preloadModel(identifier).rawValue) }
    }

    public func capacitySnapshot(withReply reply: @escaping (WorkerCapacitySnapshot?, Int) -> Void) {
        let reply = WorkerSendableBox(reply)
        Task {
            reply.value(
                await state.capacitySnapshot(),
                InferenceWorkerErrorCode.none.rawValue)
        }
    }

    public func runSandboxSelfTest(version: Int, withReply reply: @escaping (UInt64, Int) -> Void) {
        guard version == 1, ProcessInfo.processInfo.environment["DARKBLOOM_SIGNED_HOST_TEST"] == "1" else {
            reply(0, InferenceWorkerErrorCode.invalidRequest.rawValue)
            return
        }
        reply(WorkerSandboxSelfTest.run(), InferenceWorkerErrorCode.none.rawValue)
    }
}

public final class InferenceWorkerListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let runtime = InferenceWorkerRuntime()

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        do {
            try InferenceWorkerPeerIdentity.validate(connection: connection, expected: .host)
        } catch {
            return false
        }
        let service = InferenceWorkerService(runtime: runtime)
        connection.exportedInterface = InferenceWorkerXPCInterfaces.worker()
        connection.exportedObject = service
        connection.remoteObjectInterface = InferenceWorkerXPCInterfaces.host()
        guard let host = connection.remoteObjectProxyWithErrorHandler({ _ in
            service.invalidate()
        }) as? InferenceWorkerHostProtocol else { return false }
        service.attach(host: host)
        connection.invalidationHandler = { service.invalidate() }
        connection.interruptionHandler = { service.invalidate() }
        connection.resume()
        return true
    }
}

public enum WorkerSandboxSelfTest {
    public static func run() -> UInt64 {
        var denied: UInt64 = 0
        if networkClientDenied() { denied |= 1 << WorkerSandboxProbe.networkClient.rawValue }
        if networkServerDenied() { denied |= 1 << WorkerSandboxProbe.networkServer.rawValue }
        if arbitraryReadDenied() { denied |= 1 << WorkerSandboxProbe.arbitraryRead.rawValue }
        if arbitraryWriteDenied() { denied |= 1 << WorkerSandboxProbe.arbitraryWrite.rawValue }
        if childProcessDenied() { denied |= 1 << WorkerSandboxProbe.childProcess.rawValue }
        if debuggerDenied() { denied |= 1 << WorkerSandboxProbe.debugger.rawValue }
        return denied
    }

    private static func isDeniedErrno(_ value: Int32) -> Bool { value == EPERM || value == EACCES }

    private static func networkClientDenied() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return isDeniedErrno(errno) }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(9).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return status != 0 && isDeniedErrno(errno)
    }

    private static func networkServerDenied() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return isDeniedErrno(errno) }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound != 0 { return isDeniedErrno(errno) }
        let status = listen(fd, 1)
        return status != 0 && isDeniedErrno(errno)
    }

    private static func arbitraryReadDenied() -> Bool {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/.darkbloom-sandbox-read-probe").path
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        if fd >= 0 { close(fd); return false }
        return isDeniedErrno(errno)
    }

    private static func arbitraryWriteDenied() -> Bool {
        let path = "/tmp/.darkbloom-inference-worker-sandbox-write-probe"
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
        if fd >= 0 { close(fd); unlink(path); return false }
        return isDeniedErrno(errno)
    }

    private static func childProcessDenied() -> Bool {
        var pid: pid_t = 0
        var arguments: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
        defer { free(arguments[0]) }
        let status = posix_spawn(&pid, "/usr/bin/true", nil, nil, &arguments, environ)
        if status == 0 { var result: Int32 = 0; waitpid(pid, &result, 0); return false }
        return isDeniedErrno(status)
    }

    private static func debuggerDenied() -> Bool {
        var target: mach_port_name_t = 0
        let status = task_for_pid(mach_task_self_, getppid(), &target)
        if status == KERN_SUCCESS { mach_port_deallocate(mach_task_self_, target); return false }
        return true
    }
}
