import Foundation
import Network
#if canImport(os)
import os
#endif

// MARK: - Event Types

public enum CoordinatorEvent: Sendable {
    case connected
    case disconnected
    /// `ciphertext` is the **decoded** NaCl-box ciphertext (nonce ‖ tag ‖ body),
    /// i.e. base64 already stripped. `senderPublicKey` is the consumer's
    /// 32-byte X25519 ephemeral public key, also decoded.
    /// Consumers (ProviderLoop) feed both directly to NodeKeyPair.decrypt
    /// without further base64 manipulation.
    case inferenceRequest(requestId: String, ciphertext: Data, senderPublicKey: Data?)
    case cancel(requestId: String)
    case attestationChallenge(nonce: String, timestamp: String)
    case runtimeOutdated(mismatches: [RuntimeMismatch])
    /// Coordinator-driven preload. Provider should eagerly load the model
    /// (off-thread) and reply with a `loadModelStatus` outbound message
    /// when the load completes or fails.
    case loadModel(modelId: String)
    /// Coordinator-driven background prefetch. Provider should download +
    /// verify the build on disk (off-thread, no GPU load) and reply with
    /// `prefetchModelStatus` outbound messages. `priority` orders concurrent
    /// prefetches (higher = sooner). Handler wired in Layer 3.
    case prefetchModel(modelId: String, priority: Int)
    /// Coordinator's declarative desired-build map. The provider reconciles each
    /// entry: prefetch the desired build if missing, then hard-swap (advertise
    /// new, drop the previous build) once verified. Sent after register and on
    /// every change. Replaces the old push-driven migration ramp.
    case desiredModels(entries: [CoordinatorMessage.DesiredModelEntry])
    /// Coordinator informs the provider of its current trust level and status.
    case trustStatus(trustLevel: String, status: String, reason: String)
}

// MARK: - Shared State

public final class AtomicProviderStats: Sendable {
    private let _requestsServed = ManagedAtomic<UInt64>(0)
    private let _tokensGenerated = ManagedAtomic<UInt64>(0)
    // Count of completed requests whose usage chunk was missing/zero. Surfaced
    // in the daemon state file so `doctor` can flag a billing under-count.
    private let _usageGaps = ManagedAtomic<UInt64>(0)

    public init() {}

    public var requestsServed: UInt64 {
        get { _requestsServed.load() }
        set { _requestsServed.store(newValue) }
    }

    public var tokensGenerated: UInt64 {
        get { _tokensGenerated.load() }
        set { _tokensGenerated.store(newValue) }
    }

    public var usageGaps: UInt64 {
        get { _usageGaps.load() }
        set { _usageGaps.store(newValue) }
    }

    public func incrementRequestsServed() {
        _requestsServed.add(1)
    }

    public func addTokensGenerated(_ count: UInt64) {
        _tokensGenerated.add(count)
    }

    public func incrementUsageGaps() {
        _usageGaps.add(1)
    }
}

/// Lock-free atomic wrapper using os_unfair_lock for shared mutable state
/// accessed from both the heartbeat tick and the main event loop.
public final class ProviderState: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var _inferenceActive: Bool = false
    private var _currentModel: String? = nil
    private var _warmModels: [String] = []
    private var _currentModelHash: String? = nil
    private var _backendCapacity: BackendCapacity? = nil

    public init() {}

    public var inferenceActive: Bool {
        get { lock.withLock { _inferenceActive } }
        set { lock.withLock { _inferenceActive = newValue } }
    }

    public var currentModel: String? {
        get { lock.withLock { _currentModel } }
        set { lock.withLock { _currentModel = newValue } }
    }

    public var warmModels: [String] {
        get { lock.withLock { _warmModels } }
        set { lock.withLock { _warmModels = newValue } }
    }

    public var currentModelHash: String? {
        get { lock.withLock { _currentModelHash } }
        set { lock.withLock { _currentModelHash = newValue } }
    }

    public var backendCapacity: BackendCapacity? {
        get { lock.withLock { _backendCapacity } }
        set { lock.withLock { _backendCapacity = newValue } }
    }
}

// MARK: - os_unfair_lock wrapper (Sendable-safe)

private final class OSAllocatedUnfairLock: @unchecked Sendable {
    private let _lock: UnsafeMutablePointer<os_unfair_lock>

    init() {
        _lock = .allocate(capacity: 1)
        _lock.initialize(to: os_unfair_lock())
    }

    deinit {
        _lock.deinitialize(count: 1)
        _lock.deallocate()
    }

    func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(_lock)
        defer { os_unfair_lock_unlock(_lock) }
        return body()
    }
}

// MARK: - PongTracker (thread-safe timestamp for ping/pong timeout)

/// Tracks the last pong time. Updated from URLSessionWebSocketTask's sendPing
/// completion handler (runs on an arbitrary queue) and read from the ping
/// task on the cooperative thread pool.
private final class PongTracker: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var lastPong = CFAbsoluteTimeGetCurrent()

    func recordPong() {
        lock.withLock { lastPong = CFAbsoluteTimeGetCurrent() }
    }

    func elapsed() -> TimeInterval {
        lock.withLock { CFAbsoluteTimeGetCurrent() - lastPong }
    }
}

// MARK: - ManagedAtomic

private final class ManagedAtomic<Value: FixedWidthInteger>: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var value: Value

    init(_ initial: Value) {
        self.value = initial
    }

    func load() -> Value {
        lock.withLock { value }
    }

    func store(_ value: Value) {
        lock.withLock { self.value = value }
    }

    func add(_ delta: Value) {
        lock.withLock { value &+= delta }
    }
}

// MARK: - OutboundRouter (per-connection outbound delivery)

/// Routes outbound messages to the *current* connection's stream.
///
/// The stable `send` closure handed to callers (ProviderLoop) routes through
/// this so it always reaches the live session. Crucially, the outbound
/// `AsyncStream` is recreated for every connection: an `AsyncStream` is
/// single-shot, so once a session's consuming task is cancelled on disconnect
/// its iterator is permanently terminated. Reusing one stream across reconnects
/// silently dropped every outbound message -- including attestation challenge
/// responses -- after the first reconnect, leaving providers stuck
/// `hardware/untrusted reason=timeout` on an otherwise-healthy connection
/// (heartbeats and ping/pong run on separate tasks, so the socket stayed up).
///
/// A lock (matching PongTracker/ManagedAtomic) is used instead of actor
/// isolation so `send` can stay a synchronous, non-async closure.
private final class OutboundRouter: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var continuation: AsyncStream<OutboundMessage>.Continuation?

    /// Install the continuation for a new connection, finishing any prior one.
    func activate(_ cont: AsyncStream<OutboundMessage>.Continuation) {
        let previous: AsyncStream<OutboundMessage>.Continuation? = lock.withLock {
            let prev = continuation
            continuation = cont
            return prev
        }
        previous?.finish()
    }

    /// Yield a message to the current connection, if any. Messages produced
    /// while disconnected are dropped (the caller cannot reach the coordinator
    /// anyway) rather than buffered into a stream nothing is consuming.
    func yield(_ msg: OutboundMessage) {
        let cont = lock.withLock { continuation }
        cont?.yield(msg)
    }

    /// Tear down outbound delivery permanently (shutdown).
    func finish() {
        let cont: AsyncStream<OutboundMessage>.Continuation? = lock.withLock {
            let c = continuation
            continuation = nil
            return c
        }
        cont?.finish()
    }
}

// MARK: - Configuration

public struct CoordinatorClientConfig: Sendable {
    public let url: String
    public let hardware: HardwareInfo
    public let models: [ModelInfo]
    public let backendName: String
    public let heartbeatInterval: TimeInterval
    public let publicKey: String?
    public let walletAddress: String?
    public let attestation: RawJSON?
    public let authToken: String?
    public let runtimeHashes: RuntimeHashes?
    public let modelHashes: [String: String]
    public let privacyCapabilities: PrivacyCapabilities?
    /// When true, this machine registers as private-only: the coordinator
    /// serves it exclusively to its owner's self-route requests, never the
    /// public fleet.
    public let privateOnly: Bool
    /// APNs code-identity (v0.6.0): the device token to push the E_K(nonce)
    /// code-identity challenge to, and which APNs environment it belongs to.
    /// nil on headless/no-GUI boxes (no token) — those register un-attested.
    public let apnsDeviceToken: String?
    public let apnsEnvironment: String?

    public init(
        url: String,
        hardware: HardwareInfo,
        models: [ModelInfo],
        backendName: String,
        heartbeatInterval: TimeInterval = 30.0,
        publicKey: String? = nil,
        walletAddress: String? = nil,
        attestation: RawJSON? = nil,
        authToken: String? = nil,
        runtimeHashes: RuntimeHashes? = nil,
        modelHashes: [String: String] = [:],
        privacyCapabilities: PrivacyCapabilities? = nil,
        privateOnly: Bool = false,
        apnsDeviceToken: String? = nil,
        apnsEnvironment: String? = nil
    ) {
        self.url = url
        self.hardware = hardware
        self.models = models
        self.backendName = backendName
        self.heartbeatInterval = heartbeatInterval
        self.publicKey = publicKey
        self.walletAddress = walletAddress
        self.attestation = attestation
        self.authToken = authToken
        self.runtimeHashes = runtimeHashes
        self.modelHashes = modelHashes
        self.privacyCapabilities = privacyCapabilities
        self.privateOnly = privateOnly
        self.apnsDeviceToken = apnsDeviceToken
        self.apnsEnvironment = apnsEnvironment
    }
}

public struct RuntimeHashes: Sendable {
    public let pythonHash: String?
    public let runtimeHash: String?
    public let templateHashes: [String: String]

    public init(
        pythonHash: String? = nil,
        runtimeHash: String? = nil,
        templateHashes: [String: String] = [:]
    ) {
        self.pythonHash = pythonHash
        self.runtimeHash = runtimeHash
        self.templateHashes = templateHashes
    }
}

// MARK: - Outbound message type (provider -> coordinator)

public enum OutboundMessage: Sendable {
    case inferenceAccepted(requestId: String)
    case inferenceChunk(requestId: String, data: String, encryptedData: EncryptedPayload?)
    case inferenceComplete(requestId: String, usage: UsageInfo, seSignature: String?, responseHash: String?)
    case inferenceError(requestId: String, error: String, statusCode: UInt16)
    case attestationResponse(AttestationResponsePayload)
    case codeAttestationResponse(nonce: String, signature: String)
    case loadModelStatus(modelId: String, status: ProviderMessage.LoadModelStatus.Status, error: String?)
    case prefetchModelStatus(
        modelId: String,
        status: ProviderMessage.PrefetchModelStatus.Status,
        bytesDone: Int64,
        bytesTotal: Int64,
        error: String?
    )
    /// Authoritative out-of-band advertisement of newly-available builds
    /// (e.g. a verified prefetch), carrying full `ModelInfo` including the
    /// computed weight hash so the coordinator can cross-check before routing.
    case modelsUpdate(models: [ModelInfo])
}

public struct AttestationResponsePayload: Sendable {
    public let nonce: String
    public let signature: String
    public let statusSignature: String?
    public let publicKey: String
    public let hypervisorActive: Bool?
    public let rdmaDisabled: Bool?
    public let sipEnabled: Bool?
    public let secureBootEnabled: Bool?
    public let binaryHash: String?
    public let activeModelHash: String?
    public let pythonHash: String?
    public let runtimeHash: String?
    public let templateHashes: [String: String]
    public let modelHashes: [String: String]

    public init(
        nonce: String,
        signature: String,
        statusSignature: String? = nil,
        publicKey: String,
        hypervisorActive: Bool? = nil,
        rdmaDisabled: Bool? = nil,
        sipEnabled: Bool? = nil,
        secureBootEnabled: Bool? = nil,
        binaryHash: String? = nil,
        activeModelHash: String? = nil,
        pythonHash: String? = nil,
        runtimeHash: String? = nil,
        templateHashes: [String: String] = [:],
        modelHashes: [String: String] = [:]
    ) {
        self.nonce = nonce
        self.signature = signature
        self.statusSignature = statusSignature
        self.publicKey = publicKey
        self.hypervisorActive = hypervisorActive
        self.rdmaDisabled = rdmaDisabled
        self.sipEnabled = sipEnabled
        self.secureBootEnabled = secureBootEnabled
        self.binaryHash = binaryHash
        self.activeModelHash = activeModelHash
        self.pythonHash = pythonHash
        self.runtimeHash = runtimeHash
        self.templateHashes = templateHashes
        self.modelHashes = modelHashes
    }
}

// MARK: - Reachability

/// Lightweight wrapper over NWPathMonitor that tracks current network
/// reachability. The reconnect loop uses it to distinguish "the coordinator is
/// down" from "this box has no internet" — the latter is the dominant cause of
/// provider flap across the fleet and is an operator/network problem, not a
/// coordinator one. Surfacing it in reconnect telemetry makes that split
/// visible instead of every drop looking like a coordinator fault.
final class ReachabilityMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dev.darkbloom.reachability")
    private let lock = NSLock()
    private var _reachable = true

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self._reachable = (path.status == .satisfied)
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    var isReachable: Bool {
        lock.lock(); defer { lock.unlock() }
        return _reachable
    }

    func stop() { monitor.cancel() }
}

// MARK: - Coordinator Client Actor

public actor CoordinatorClient {
    private let config: CoordinatorClientConfig
    private let stats: AtomicProviderStats
    private let state: ProviderState

    private let logger = Logger(subsystem: "dev.darkbloom.provider", category: "coordinator")

    /// Tracks whether the box currently has a usable network path, so reconnect
    /// logs/telemetry can attribute flap to local connectivity vs the coordinator.
    private let reachability = ReachabilityMonitor()

    private var eventContinuation: AsyncStream<CoordinatorEvent>.Continuation?
    /// Holds the current connection's outbound continuation. The outbound stream
    /// is recreated per connection (see OutboundRouter / connectAndRun); reusing
    /// one AsyncStream across reconnects silently kills outbound delivery.
    private let outboundRouter = OutboundRouter()

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    /// Device token that arrived after the initial registration (APNs slow at
    /// startup). Once set, every (re)registration carries it. See refreshAPNsToken.
    private var apnsTokenOverride: String?

    /// Live per-model weight hashes pushed by the provider loop when a model
    /// (re)load discovers the on-disk weights changed (model re-published while
    /// the daemon runs). Once set, every (re)registration patches
    /// models[].weight_hash so the coordinator's per-model catalog filter sees
    /// current values instead of the daemon-start snapshot. Unlike
    /// refreshAPNsToken this does NOT force a reconnect — challenge responses
    /// already carry the fresh hashes live; this only keeps future
    /// registrations consistent.
    private var modelWeightHashOverrides: [String: String] = [:]

    private var shutdownRequested = false

    /// Mutable advertised-model list. Seeded from `config.models`; background
    /// prefetch (Layer 3) appends newly-verified builds so re-registration and
    /// reconnects pick them up without dropping the currently-served model.
    private let advertisedModelStore: AdvertisedModelStore

    public init(
        config: CoordinatorClientConfig,
        stats: AtomicProviderStats,
        state: ProviderState
    ) {
        self.config = config
        self.stats = stats
        self.state = state
        self.advertisedModelStore = AdvertisedModelStore(config.models)
    }

    /// Add a runtime-verified build to the advertised set so the coordinator
    /// sees it on the NEXT registration (reconnect). Returns true if the model
    /// was newly advertised. The store always holds the FULL union (startup ∪
    /// prefetched), so the currently-served model is never dropped during the
    /// transition — registration carries old + new.
    ///
    /// Why not force a mid-connection re-register here: re-sending a `register`
    /// on the live socket makes the coordinator construct a brand-new provider
    /// record — resetting reputation, re-running attestation, and starting a
    /// SECOND challenge loop alongside the first. That is too disruptive to the
    /// model this provider is actively serving. The clean instant-pickup path is
    /// a dedicated, non-resetting coordinator `models_update` message (Layer 4);
    /// until then the new build is loadable locally immediately (it is in the
    /// advertised set + appears warm in heartbeats once loaded) and is added to
    /// the coordinator's advertised inventory on the next reconnect.
    @discardableResult
    public func advertiseModel(_ model: ModelInfo) -> Bool {
        let isNew = advertisedModelStore.add(model)
        if isNew {
            logger.info("advertiseModel(\(model.id)): added to advertised set (\(self.advertisedModelStore.models.count) total); coordinator picks it up on next registration")
        }
        return isNew
    }

    /// Retire a build from the advertised set (hard swap). After this, a register
    /// or reconnect no longer announces the superseded build to the coordinator.
    @discardableResult
    public func unadvertiseModel(_ modelID: String) -> Bool {
        let removed = advertisedModelStore.remove(id: modelID)
        if removed {
            logger.info("unadvertiseModel(\(modelID)): dropped from advertised set (\(self.advertisedModelStore.models.count) total)")
        }
        return removed
    }

    /// Snapshot of the current advertised model list (startup ∪ runtime
    /// prefetched builds).
    public func currentAdvertisedModels() -> [ModelInfo] {
        advertisedModelStore.models
    }

    /// Start the connection loop. Returns an AsyncStream of events for the caller
    /// to consume, and provides a way to send outbound messages.
    public func start() -> (events: AsyncStream<CoordinatorEvent>, send: @Sendable (OutboundMessage) -> Void) {
        let (eventStream, eventCont) = AsyncStream<CoordinatorEvent>.makeStream()
        self.eventContinuation = eventCont

        // The outbound stream is created per-connection inside connectAndRun and
        // registered with the router; the stable send closure always routes
        // through the router to the live session.
        let router = self.outboundRouter
        let sendFn: @Sendable (OutboundMessage) -> Void = { msg in
            router.yield(msg)
        }

        Task { [weak self] in
            guard let self else { return }
            await self.runLoop()
        }

        return (eventStream, sendFn)
    }

    public func shutdown() {
        shutdownRequested = true
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        eventContinuation?.finish()
        outboundRouter.finish()
    }

    /// Re-register over a fresh connection carrying a device token that arrived
    /// after the initial registration. Cancelling the socket (without setting
    /// `shutdownRequested`) surfaces as a connection error, so the reconnect loop
    /// re-runs `sendRegistration` with the override token — letting the
    /// coordinator bind T↔K and push the code-identity challenge. No-op if the
    /// token is unchanged.
    public func refreshAPNsToken(_ token: String) {
        guard apnsTokenOverride != token else { return }
        apnsTokenOverride = token
        webSocketTask?.cancel(with: .goingAway, reason: nil)
    }

    /// Record refreshed per-model weight hashes for use in future
    /// (re)registrations. Called by the provider loop after a model (re)load
    /// recomputes the on-disk weight hash. See `modelWeightHashOverrides`.
    public func updateModelWeightHashes(_ hashes: [String: String]) {
        modelWeightHashOverrides = hashes
    }

    // MARK: - Connection Loop

    private func runLoop() async {
        var backoff = ExponentialBackoff(base: 1.0, max: 30.0)
        var reconnectCount: UInt64 = 0

        while !shutdownRequested {
            logger.info("Connecting to coordinator: \(self.config.url)")

            do {
                try await connectAndRun()
                logger.info("Coordinator connection closed, reconnecting...")
                backoff.reset()
                continue
            } catch {
                if shutdownRequested { break }

                eventContinuation?.yield(.disconnected)
                let delay = backoff.nextDelay()
                let reachable = reachability.isReachable
                logger.warning("Coordinator connection error: \(error.localizedDescription). network_reachable=\(reachable). Reconnecting in \(delay)s")

                reconnectCount += 1
                if shouldEmitReconnectTelemetry(count: reconnectCount) {
                    emitReconnectTelemetry(count: reconnectCount, error: error)
                }

                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    // Task cancelled = shutdown
                    break
                }
            }
        }

        logger.info("Coordinator client shut down")
        eventContinuation?.finish()
    }

    // MARK: - Single Connection Session

    private func connectAndRun() async throws {
        guard let url = URL(string: config.url) else {
            throw CoordinatorError.invalidURL(config.url)
        }

        let session = URLSession(configuration: .default)
        self.urlSession = session
        let ws = session.webSocketTask(with: url)
        self.webSocketTask = ws
        ws.resume()

        try await sendRegistration(ws: ws)
        logger.info("Sent registration to coordinator")

        // Fresh outbound stream for THIS connection. AsyncStream is single-shot:
        // its iterator is terminated when the previous session's consumer task is
        // cancelled on disconnect, so a reused stream would never deliver another
        // message. Recreating it per connection (and routing the stable send
        // closure through outboundRouter) is what keeps attestation responses and
        // inference replies flowing after a reconnect. Activate before announcing
        // .connected so any immediate outbound is buffered, not dropped.
        let (outboundStream, outboundCont) = AsyncStream<OutboundMessage>.makeStream()
        outboundRouter.activate(outboundCont)

        eventContinuation?.yield(.connected)

        try await sessionLoop(ws: ws, outboundStream: outboundStream)
    }

    private func sessionLoop(
        ws: URLSessionWebSocketTask,
        outboundStream: AsyncStream<OutboundMessage>
    ) async throws {
        let pingInterval: TimeInterval = 10.0
        let pongTimeout: TimeInterval = 30.0

        // Thread-safe pong timestamp: updated from sendPing's callback (arbitrary queue),
        // read from the ping task. Using an actor would force structured concurrency
        // overhead on every ping; an unfair lock is cheaper for a single Instant.
        let pongTracker = PongTracker()

        try await withThrowingTaskGroup(of: Void.self) { group in
            // Task 1: Receive messages from coordinator
            group.addTask { [weak self] in
                guard let self else { return }
                try await self.receiveLoop(ws: ws)
            }

            // Task 2: Forward outbound messages to coordinator
            group.addTask { [weak self] in
                guard let self else { return }
                for await msg in outboundStream {
                    let shutting = await self.shutdownRequested
                    if shutting { break }
                    let json = await self.encodeOutbound(msg)
                    try await ws.send(.string(json))
                }
            }

            // Task 3: Heartbeat timer
            group.addTask { [weak self] in
                guard let self else { return }
                let interval = await self.config.heartbeatInterval

                try await Task.sleep(for: .seconds(interval))

                while true {
                    let shutting = await self.shutdownRequested
                    if shutting { break }
                    let json = await self.buildHeartbeatJSON()
                    try await ws.send(.string(json))
                    try await Task.sleep(for: .seconds(interval))
                }
            }

            // Task 4: Ping timer with pong timeout detection
            group.addTask {
                while true {
                    try await Task.sleep(for: .seconds(pingInterval))

                    if pongTracker.elapsed() > pongTimeout {
                        throw CoordinatorError.pongTimeout
                    }

                    ws.sendPing { error in
                        if error == nil {
                            pongTracker.recordPong()
                        }
                    }
                }
            }

            do {
                try await group.next()
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    // MARK: - Receive Loop

    private func receiveLoop(ws: URLSessionWebSocketTask) async throws {
        while !shutdownRequested {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await ws.receive()
            } catch {
                throw CoordinatorError.connectionClosed(error)
            }

            switch message {
            case .string(let text):
                await handleIncomingText(text, ws: ws)
            case .data(let data):
                if let text = String(data: data, encoding: .utf8) {
                    await handleIncomingText(text, ws: ws)
                }
            @unknown default:
                break
            }
        }
    }

    private func handleIncomingText(_ text: String, ws: URLSessionWebSocketTask) async {
        guard let data = text.data(using: .utf8) else { return }

        let parsed: CoordinatorMessage
        do {
            parsed = try CoordinatorClientCodec.decodeIncomingMessage(from: data)
        } catch {
            logger.warning("Failed to parse coordinator message: \(error.localizedDescription)")
            return
        }

        switch parsed {
        case .inferenceRequest(let request):
            let requestId = request.requestId
            logger.info("Received inference request: \(requestId)")

            guard let encrypted = request.encryptedBody else {
                logger.error("Rejecting plaintext inference request: \(requestId)")
                let errorResponse = encodeInferenceError(
                    requestId: requestId,
                    error: "coordinator text request missing encrypted body",
                    statusCode: 400
                )
                try? await ws.send(.string(errorResponse))
                return
            }

            // Decode the wire form here so consumers don't have to. NaCl box
            // wire format is `base64(nonce ‖ tag ‖ body)`; we strip base64
            // once and pass raw bytes upstream. Same for the sender's
            // ephemeral pubkey (32 bytes).
            guard let cipherBytes = Data(base64Encoded: encrypted.ciphertext) else {
                logger.error("Rejecting inference request \(requestId): ciphertext is not valid base64")
                let errorResponse = encodeInferenceError(
                    requestId: requestId,
                    error: "ciphertext is not valid base64",
                    statusCode: 400
                )
                try? await ws.send(.string(errorResponse))
                return
            }
            let senderKeyBytes = Data(base64Encoded: encrypted.ephemeralPublicKey)
            if senderKeyBytes == nil || senderKeyBytes?.count != 32 {
                logger.error("Rejecting inference request \(requestId): invalid ephemeral public key")
                let errorResponse = encodeInferenceError(
                    requestId: requestId,
                    error: "invalid ephemeral_public_key",
                    statusCode: 400
                )
                try? await ws.send(.string(errorResponse))
                return
            }

            eventContinuation?.yield(.inferenceRequest(
                requestId: requestId,
                ciphertext: cipherBytes,
                senderPublicKey: senderKeyBytes
            ))

        case .cancel(let cancel):
            let requestId = cancel.requestId
            logger.info("Received cancel for: \(requestId)")
            eventContinuation?.yield(.cancel(requestId: requestId))

        case .attestationChallenge(let challenge):
            logger.info("Received attestation challenge")
            eventContinuation?.yield(.attestationChallenge(
                nonce: challenge.nonce,
                timestamp: challenge.timestamp
            ))

        case .runtimeStatus(let status):
            if status.verified {
                logger.info("Runtime integrity verified by coordinator")
            } else {
                logger.warning("Runtime integrity check FAILED -- \(status.mismatches.count) mismatch(es)")
                for m in status.mismatches {
                    logger.warning("  \(m.component): expected=\(m.expected), got=\(m.got)")
                }
                eventContinuation?.yield(.runtimeOutdated(mismatches: status.mismatches))
            }

        case .loadModel(let load):
            logger.info("Received coordinator-driven preload for: \(load.modelId)")
            eventContinuation?.yield(.loadModel(modelId: load.modelId))

        case .prefetchModel(let pf):
            // Background download-only request. Forwarded to ProviderLoop, which
            // downloads + verifies the build on disk (no GPU load) and replies
            // with prefetch_model_status messages.
            logger.info("Received coordinator-driven prefetch for: \(pf.modelId) (priority=\(pf.priority))")
            eventContinuation?.yield(.prefetchModel(modelId: pf.modelId, priority: pf.priority))

        case .desiredModels(let dm):
            // Declarative desired-state. ProviderLoop reconciles each entry:
            // prefetch the desired build if missing, then hard-swap once verified.
            logger.info("Received desired_models from coordinator: \(dm.models.count) entr(ies)")
            eventContinuation?.yield(.desiredModels(entries: dm.models))

        case .trustStatus(let ts):
            logger.info("Trust status from coordinator: level=\(ts.trustLevel) status=\(ts.status) reason=\(ts.reason)")
            eventContinuation?.yield(.trustStatus(
                trustLevel: ts.trustLevel,
                status: ts.status,
                reason: ts.reason
            ))
        }
    }

    // MARK: - Registration

    private func sendRegistration(ws: URLSessionWebSocketTask) async throws {
        let privacyCapabilities = config.privacyCapabilities ?? PrivacyCapabilities(
            textBackendInprocess: true,
            textProxyDisabled: true,
            pythonRuntimeLocked: true,
            dangerousModulesBlocked: true,
            sipEnabled: SecurityChecks.isSIPEnabled(),
            antiDebugEnabled: true,
            coreDumpsDisabled: true,
            envScrubbed: true,
            hypervisorActive: SecurityChecks.isHypervisorActive()
        )
        // Read the live advertised list (startup ∪ prefetched builds) rather
        // than the immutable `config.models`, so a re-registration after a
        // verified prefetch carries the updated set.
        let jsonData = try CoordinatorClientCodec.encodeRegistration(
            from: config,
            models: advertisedModelStore.models,
            privacyCapabilities: privacyCapabilities,
            apnsDeviceTokenOverride: apnsTokenOverride,
            modelWeightHashOverrides: modelWeightHashOverrides
        )
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw CoordinatorError.encodingFailed
        }
        try await ws.send(.string(jsonString))
    }

    // MARK: - Heartbeat

    private func buildHeartbeatJSON() -> String {
        let isActive = state.inferenceActive
        let activeModel = state.currentModel
        let warmModels = state.warmModels
        let capacity = state.backendCapacity
        let metrics = SystemMetricsCollector.collect(cpuCores: config.hardware.cpuCores.total)

        let message = CoordinatorClientCodec.heartbeatMessage(
            status: isActive ? .serving : .idle,
            activeModel: activeModel,
            warmModels: warmModels,
            stats: ProviderStats(
                requestsServed: stats.requestsServed,
                tokensGenerated: stats.tokensGenerated
            ),
            systemMetrics: metrics,
            backendCapacity: capacity
        )

        guard let data = try? ProviderProtocolCodec.encodeProviderMessage(message),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"type\":\"heartbeat\",\"status\":\"idle\",\"stats\":{\"requests_served\":0,\"tokens_generated\":0},\"system_metrics\":{\"memory_pressure\":0,\"cpu_usage\":0,\"thermal_state\":\"nominal\"}}"
        }
        return json
    }

    // MARK: - Outbound Encoding

    private func encodeOutbound(_ msg: OutboundMessage) -> String {
        (try? CoordinatorClientCodec.encodeOutboundMessageString(msg)) ?? "{}"
    }

    private func encodeInferenceError(requestId: String, error: String, statusCode: UInt16) -> String {
        let message = ProviderMessage.inferenceError(ProviderMessage.InferenceError(
            requestId: requestId,
            error: error,
            statusCode: statusCode
        ))
        guard let data = try? ProviderProtocolCodec.encodeProviderMessage(message),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    // MARK: - Telemetry

    /// Telemetry gate: emit at counts 3, 10, then every 30.
    private func shouldEmitReconnectTelemetry(count: UInt64) -> Bool {
        count == 3 || count == 10 || count % 30 == 0
    }

    private func emitReconnectTelemetry(count: UInt64, error: Error) {
        let reachable = reachability.isReachable
        TelemetryClient.shared.emit(
            kind: .connectivity,
            severity: .warn,
            message: "coordinator reconnect",
            fields: [
                "reconnect_count": .int(Int(count)),
                "last_error": .string(error.localizedDescription),
                "coordinator_url": .string(config.url),
                // Distinguishes "coordinator down" from "box lost internet" —
                // the latter is the dominant, operator-side cause of flap.
                "network_reachable": .bool(reachable),
            ]
        )
        logger.warning("Reconnect telemetry: count=\(count) network_reachable=\(reachable) error=\(error.localizedDescription)")
    }
}

// MARK: - Errors

public enum CoordinatorError: Error, CustomStringConvertible {
    case invalidURL(String)
    case encodingFailed
    case pongTimeout
    case connectionClosed(Error)

    public var description: String {
        switch self {
        case .invalidURL(let url): return "Invalid coordinator URL: \(url)"
        case .encodingFailed: return "Failed to encode message"
        case .pongTimeout: return "WebSocket pong timeout (no response in 30s)"
        case .connectionClosed(let err): return "WebSocket connection closed: \(err.localizedDescription)"
        }
    }
}

// MARK: - Security Checks Namespace

/// Stub namespace for security checks. The Security module will provide
/// real implementations; these stubs ensure the coordinator client compiles
/// and runs independently.
enum SecurityChecks {
    static func isSIPEnabled() -> Bool {
        SIPStatusChecker().isFullyEnabled()
    }

    static func isHypervisorActive() -> Bool {
        false
    }
}

// MARK: - Logger (os.Logger on macOS, stderr fallback)

#if canImport(os)
private typealias Logger = os.Logger
#else
private struct Logger {
    let subsystem: String
    let category: String

    func info(_ msg: String) { print("[\(category)] INFO: \(msg)") }
    func warning(_ msg: String) { print("[\(category)] WARN: \(msg)") }
    func error(_ msg: String) { print("[\(category)] ERROR: \(msg)") }
}
#endif
