import Foundation

/// Qualification-only transport for a single ProviderLoop endpoint. There is no
/// key export, sign(hash) RPC, provider restart, or fallback to in-process Apple.
public actor AppAttestWorkerClient: AppAttestWorkerExchangeClient {
    public typealias CustodyOperation = @Sendable (AppAttestWorkerCustodyRequest) async throws -> String

    /// An observation for the local qualification report, never a capability to
    /// signal a PID later. All worker signalling remains inside this supervisor.
    public struct QualificationSuspension: Sendable {
        public let processID: Int32
        public let workerGeneration: UUID
        public let auditToken: Data
    }

    public struct QualificationAssertionEvent: Sendable {
        public enum Phase: String, Codable, Sendable {
            case submitted
            case callbackDiscarded = "callback_discarded"
        }
        /// Historical observation only, never an input to a signal operation.
        public let processID: Int32
        public let workerGeneration: UUID
        public let sequence: UInt64
        public let phase: Phase
    }

    private let scope: String
    private let endpointPublicKey: String
    private let custody: CustodyOperation
    private let processes = WorkerProcessSlot()
    private var connection: Connection?
    private var activeExchange: UUID?
    private var retirements = 0
    private var stopped = false
    private var account: String?
    private var environment: String?
    private var assertionFault: AssertionFault?
    private var qualificationArmedGeneration: UUID?
    private let assertionEventQueue = DispatchQueue(label: "io.darkbloom.app-attest.qualification-events")

    public init(scope: String, endpointPublicKey: String, custody: @escaping CustodyOperation) throws {
        guard AppAttestWorkerSelection.qualificationCandidateEnabled else { throw AppAttestWorkerError.qualificationRequired }
        guard !scope.isEmpty, scope.utf8.count <= 2048, WorkerRequestValidation.canonical32(endpointPublicKey) else {
            throw AppAttestWorkerError.invalidMessage
        }
        self.scope = scope
        self.endpointPublicKey = endpointPublicKey
        self.custody = custody
    }

    public func respond(to request: AppAttestShadowPayload, status: AppAttestStatus) async throws -> AppAttestWorkerReply {
        guard !stopped else { throw AppAttestWorkerError.stopped }
        guard activeExchange == nil, retirements == 0 else { throw AppAttestWorkerError.busy }
        try WorkerRequestValidation.validate(request, status: status)
        guard account == nil || account == request.accountScope,
              environment == nil || environment == request.environment else {
            try await stop()
            throw AppAttestWorkerError.invalidMessage
        }
        if account == nil {
            guard request.action == "prepare" else { throw AppAttestWorkerError.staleExchange }
            account = request.accountScope; environment = request.environment
        }
        let exchange = UUID()
        activeExchange = exchange
        defer { if activeExchange == exchange { activeExchange = nil } }
        let epoch = try processes.currentEpoch()
        let processes = self.processes
        // 80s plus bounded TERM/KILL/reap remains inside the coordinator's 90s
        // exchange window. Neither an Apple callback nor worker progress renews it.
        let deadline = WorkerDeadline(seconds: 80)
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                if connection == nil {
                    guard request.action == "prepare" else { throw AppAttestWorkerError.staleExchange }
                    let launched = try await launch(epoch: epoch, deadline: deadline)
                    try requireCurrent(exchange, epoch: epoch)
                    connection = launched
                }
                guard var current = connection else { throw AppAttestWorkerError.stopped }
                guard current.identity.binaryHash == status.binaryHash else { throw AppAttestWorkerError.executableChanged }
                var message = request
                if message.action == "assert" {
                    guard message.challenge == nil, let encrypted = message.encryptedChallenge else {
                        throw AppAttestWorkerError.invalidMessage
                    }
                    message.challenge = try await proveCustody(AppAttestWorkerCustodyRequest(
                        purpose: .assertion, generation: current.order.generation,
                        session: message.session, encryptedChallenge: encrypted), deadline: deadline)
                    guard let clear = message.challenge, WorkerRequestValidation.canonical32(clear) else {
                        throw AppAttestWorkerError.invalidMessage
                    }
                    message.encryptedChallenge = nil
                }
                try requireCurrent(exchange, epoch: epoch)
                let sequence = try current.order.next()
                let fault = assertionFault
                if let fault {
                    guard message.action == "assert", fault.generation == current.order.generation,
                          fault.sequence == sequence else { throw AppAttestWorkerError.invalidMessage }
                    assertionFault = nil
                }
                connection = current
                let frame = WorkerFrame(generation: current.order.generation, sequence: sequence, body: .exchange(message, status))
                let transport = current
                let session = message.session
                let eventQueue = assertionEventQueue
                let reply = try await Task.detached(priority: .utility) {
                    try transport.authenticate()
                    try WorkerFraming.send(frame, to: transport.socket, deadline: deadline)
                    var eventOrder = WorkerAssertionEventOrder()
                    while true {
                        let response = try WorkerFraming.read(WorkerFrame.self, from: transport.socket, deadline: deadline)
                        try transport.authenticate()
                        try transport.order.require(response)
                        switch response.body {
                        case .assertionQualificationEvent(let phase):
                            guard let fault else { throw AppAttestWorkerError.invalidMessage }
                            try eventOrder.accept(phase)
                            let event = QualificationAssertionEvent(processID: transport.process.pid, workerGeneration: fault.generation,
                                                                    sequence: fault.sequence, phase: phase)
                            // Observers cannot hold up IPC or renew the 80s budget.
                            // A serial queue preserves the two bounded event phases.
                            eventQueue.async { fault.onEvent(event) }
                        case .reply(let reply):
                            guard reply.payload.session == session, reply.payload.protocolVersion == 3 else {
                                throw AppAttestWorkerError.invalidMessage
                            }
                            return reply
                        default:
                            throw AppAttestWorkerError.invalidMessage
                        }
                    }
                }.value
                try requireCurrent(exchange, epoch: epoch)
                if reply.operationOutstanding || reply.payload.result == "operation_timeout" {
                    clearConnection()
                    try await Task.detached { try processes.cancel(expectedEpoch: epoch) }.value
                }
                return reply
            } catch {
                if activeExchange == exchange { clearConnection() }
                try await Task.detached { try processes.cancel(expectedEpoch: epoch) }.value
                throw error
            }
        } onCancel: {
            // This path runs even if the worker is stuck in a synchronous native
            // call. The epoch prevents a late cancellation from killing a successor.
            Task.detached { try? processes.cancel(expectedEpoch: epoch) }
        }
    }

    public func cancelExchange() async throws {
        try await retireWorker(permanently: false)
    }

    public func stop() async throws {
        stopped = true
        try await retireWorker(permanently: true)
    }

    /// The next RPC must be the normal typed assertion exchange. This arms one
    /// real invocation's callback discard, not a caller-selected key or hash.
    public func armNextAssertionCallbackDiscardForQualification(
        onEvent: @escaping @Sendable (QualificationAssertionEvent) -> Void
    ) async throws {
        guard AppAttestWorkerSelection.qualificationCandidateEnabled else { throw AppAttestWorkerError.qualificationRequired }
        guard !stopped else { throw AppAttestWorkerError.stopped }
        guard activeExchange == nil, retirements == 0, var current = connection,
              qualificationArmedGeneration != current.order.generation else { throw AppAttestWorkerError.busy }
        let sequence = try current.order.next()
        guard sequence < UInt64.max else { throw AppAttestWorkerError.staleExchange }
        let exchange = UUID()
        activeExchange = exchange
        defer { if activeExchange == exchange { activeExchange = nil } }
        connection = current
        let epoch = try processes.currentEpoch()
        let processes = self.processes
        let transport = current
        let deadline = WorkerDeadline(seconds: 5)
        try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                try await Task.detached(priority: .utility) {
                    try transport.authenticate()
                    try WorkerFraming.send(WorkerFrame(generation: transport.order.generation, sequence: sequence,
                        body: .armAssertionCallbackDiscard), to: transport.socket, deadline: deadline)
                    let response = try WorkerFraming.read(WorkerFrame.self, from: transport.socket, deadline: deadline)
                    try transport.authenticate()
                    try transport.order.require(response)
                    guard case .assertionCallbackDiscardArmed = response.body else { throw AppAttestWorkerError.invalidMessage }
                }.value
                try requireCurrent(exchange, epoch: epoch)
                qualificationArmedGeneration = current.order.generation
                assertionFault = AssertionFault(generation: current.order.generation, sequence: sequence + 1, onEvent: onEvent)
            } catch {
                if activeExchange == exchange { clearConnection() }
                try await Task.detached { try processes.cancel(expectedEpoch: epoch) }.value
                throw error
            }
        } onCancel: {
            Task.detached { try? processes.cancel(expectedEpoch: epoch) }
        }
    }

    /// Fault injection for the signed, local qualification runner only. The
    /// caller supplies no PID; an old connection cannot suspend its replacement.
    public func suspendOwnedWorkerForQualification() async throws -> QualificationSuspension {
        guard AppAttestWorkerSelection.qualificationCandidateEnabled else { throw AppAttestWorkerError.qualificationRequired }
        try Task.checkCancellation()
        guard !stopped else { throw AppAttestWorkerError.stopped }
        guard retirements == 0, let current = connection else { throw AppAttestWorkerError.busy }
        let processes = self.processes
        let epoch = try processes.currentEpoch()
        try await Task.detached(priority: .utility) {
            try current.authenticate()
            try processes.suspendOwnedWorkerForQualification(expectedEpoch: epoch, expectedProcess: current.process)
        }.value
        try Task.checkCancellation()
        guard !stopped, let latest = connection, latest.process === current.process,
              try processes.currentEpoch() == epoch else { throw AppAttestWorkerError.staleExchange }
        return QualificationSuspension(processID: current.process.pid, workerGeneration: current.order.generation,
                                       auditToken: current.peer.bytes)
    }

    private func retireWorker(permanently: Bool) async throws {
        retirements += 1
        activeExchange = nil
        clearConnection()
        let processes = self.processes
        defer { retirements -= 1 }
        try await Task.detached { try processes.cancel(permanently: permanently) }.value
    }

    private func clearConnection() {
        connection = nil
        assertionFault = nil
        qualificationArmedGeneration = nil
    }

    private func requireCurrent(_ exchange: UUID, epoch: UInt64) throws {
        try Task.checkCancellation()
        guard !stopped, activeExchange == exchange, try processes.currentEpoch() == epoch else {
            throw AppAttestWorkerError.staleExchange
        }
    }

    private func launch(epoch: UInt64, deadline: WorkerDeadline) async throws -> Connection {
        let scope = self.scope, endpoint = endpointPublicKey, processes = self.processes
        let qualificationFaultsAllowed = AppAttestWorkerSelection.qualificationCandidateEnabled
        let generation = UUID()
        let (connection, challenge) = try await Task.detached(priority: .utility) {
            guard Bundle.main.bundleURL.pathExtension == "app" else { throw AppAttestWorkerError.unauthenticatedPeer }
            let identity = try WorkerCodeIdentity.current()
            let listener = try WorkerListener()
            let bootstrap = WorkerBootstrap(version: WorkerBootstrap.version, generation: generation,
                                            secret: AppAttestWorkerHost.randomBytes(), parentAuditToken: try WorkerAuditIdentity.current().bytes,
                                            socketPath: listener.path, scope: scope, endpointPublicKey: endpoint,
                                            qualificationFaultsAllowed: qualificationFaultsAllowed)
            let child = try processes.launch(executable: identity.executable, arguments: [AppAttestWorkerHost.argument],
                                            bootstrap: WorkerFraming.encode(bootstrap, limit: 4092), epoch: epoch)
            let authenticationDeadline = WorkerDeadline(seconds: min(10, deadline.remaining))
            let socket = try listener.accept(deadline: authenticationDeadline)
            try processes.attach(socket, epoch: epoch)
            let peer = try WorkerAuditIdentity.peer(socket)
            try child.requireAlive()
            try identity.authenticate(peer, expectedPID: child.pid)
            let order = WorkerExchangeOrder(generation: generation)
            let hello = try WorkerFraming.read(WorkerFrame.self, from: socket, deadline: authenticationDeadline)
            try order.require(hello)
            guard case .hello(let secret) = hello.body, secret == bootstrap.secret else {
                throw AppAttestWorkerError.unauthenticatedPeer
            }
            let challenge = try WorkerFraming.read(WorkerFrame.self, from: socket, deadline: authenticationDeadline)
            try order.require(challenge)
            guard case .custodyChallenge(let encrypted) = challenge.body,
                  WorkerRequestValidation.canonical32(encrypted.ephemeralPublicKey),
                  let ciphertext = Data(base64Encoded: encrypted.ciphertext), (40...512).contains(ciphertext.count) else {
                throw AppAttestWorkerError.invalidMessage
            }
            return (Connection(process: child, socket: socket, identity: identity, peer: peer, order: order), encrypted)
        }.value
        let handshakeDeadline = WorkerDeadline(seconds: min(5, deadline.remaining))
        let answer = try await proveCustody(AppAttestWorkerCustodyRequest(purpose: .workerBinding, generation: generation,
                                                                        session: "", encryptedChallenge: challenge), deadline: handshakeDeadline)
        guard answer.hasPrefix("darkbloom.app-attest.worker-custody.v1:\(generation.uuidString):"), answer.utf8.count <= 160 else {
            throw AppAttestWorkerError.unauthenticatedPeer
        }
        try await Task.detached(priority: .utility) {
            try connection.authenticate()
            try WorkerFraming.send(WorkerFrame(generation: generation, sequence: 0, body: .custodyAnswer(answer)),
                                   to: connection.socket, deadline: handshakeDeadline)
            let response = try WorkerFraming.read(WorkerFrame.self, from: connection.socket, deadline: handshakeDeadline)
            try connection.order.require(response)
            guard case .authenticated = response.body else { throw AppAttestWorkerError.unauthenticatedPeer }
        }.value
        return connection
    }

    private func proveCustody(_ request: AppAttestWorkerCustodyRequest, deadline: WorkerDeadline) async throws -> String {
        let custody = self.custody
        let task = Task.detached { try await custody(request) }
        defer { task.cancel() }
        return try await CallbackDeadline.call(seconds: min(5, deadline.remaining)) { complete in
            Task {
                do { complete(.success(try await task.value)) }
                catch { complete(.failure(error)) }
            }
        }
    }

    private struct AssertionFault: Sendable {
        let generation: UUID
        let sequence: UInt64
        let onEvent: @Sendable (QualificationAssertionEvent) -> Void
    }

    private struct Connection: Sendable {
        let process: WorkerProcess
        let socket: WorkerDescriptor
        let identity: WorkerCodeIdentity
        let peer: WorkerAuditIdentity
        var order: WorkerExchangeOrder
        func authenticate() throws {
            try process.requireAlive()
            guard try WorkerAuditIdentity.peer(socket) == peer else { throw AppAttestWorkerError.unauthenticatedPeer }
            try identity.authenticate(peer, expectedPID: process.pid, expectedAudit: peer.bytes, fullMeasurement: false)
        }
    }
}
