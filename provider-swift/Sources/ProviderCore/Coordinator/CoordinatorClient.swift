import Foundation
import Network
#if canImport(os)
import os
#endif


// MARK: - Coordinator Client Actor

// Access note: stored state and the methods reached across the split are
// `internal` (not `private`) so this actor can be split by concern across the
// CoordinatorClient+Connection/+Inbound/+Registration/+Outbound files in this
// module (Swift `private` is file-scoped). Only members reached across the split
// are widened; behavior is unchanged.
public actor CoordinatorClient {
    /// Upper bound on a single inbound WebSocket message. The coordinator sends each
    /// inference request as ONE text frame carrying the base64 NaCl-box of the full
    /// body; for a vision request that frame includes base64-encoded image bytes and
    /// can be several MiB. `URLSessionWebSocketTask` defaults to a 1 MiB cap and
    /// THROWS on any larger frame, which tears down the entire session and cancels
    /// every unrelated in-flight request on this provider (then reconnects with
    /// backoff). Size this comfortably above the coordinator's 16 MiB sealed-body cap
    /// after base64 expansion (×4/3 ≈ 21.3 MiB).
    static let maxInboundMessageBytes = 32 * 1024 * 1024

    /// Raise a task's inbound message limit to ``maxInboundMessageBytes``. Factored
    /// out so a unit test can assert the limit is applied without opening a live
    /// socket.
    static func applyInboundMessageLimit(to task: URLSessionWebSocketTask) {
        task.maximumMessageSize = maxInboundMessageBytes
    }

    internal let config: CoordinatorClientConfig
    internal let stats: AtomicProviderStats
    internal let state: ProviderState

    internal let logger = CoordinatorWSLogger(subsystem: "dev.darkbloom.provider", category: "coordinator")

    /// Tracks whether the box currently has a usable network path, so reconnect
    /// logs/telemetry can attribute flap to local connectivity vs the coordinator.
    internal let reachability = ReachabilityMonitor()

    internal var eventContinuation: AsyncStream<CoordinatorEvent>.Continuation?
    /// Holds the current connection's outbound continuation. The outbound stream
    /// is recreated per connection (see OutboundRouter / connectAndRun); reusing
    /// one AsyncStream across reconnects silently kills outbound delivery.
    internal let outboundRouter = OutboundRouter()

    internal var webSocketTask: URLSessionWebSocketTask?
    internal var urlSession: URLSession?
    /// Device token that arrived after the initial registration (APNs slow at
    /// startup). Once set, every (re)registration carries it. See refreshAPNsToken.
    internal var apnsTokenOverride: String?

    /// Live APNs device-token source, read by every heartbeat. Defaults to the
    /// process-wide ``APNsBridge`` so a token that ROTATES after registration is
    /// reflected in the next heartbeat — `apnsTokenOverride`/`config` only hold the
    /// value captured at startup, and the late-token watcher in `ProviderLoop`
    /// stops after the first token, so a rotation would otherwise keep the
    /// coordinator pushing code-identity challenges to the dead token until a
    /// reconnect. Injectable so unit tests drive rotation deterministically.
    internal let liveAPNsToken: @Sendable () -> String?

    /// Live per-model weight hashes pushed by the provider loop when a model
    /// (re)load discovers the on-disk weights changed (model re-published while
    /// the daemon runs). Once set, every (re)registration patches
    /// models[].weight_hash so the coordinator's per-model catalog filter sees
    /// current values instead of the daemon-start snapshot. Unlike
    /// refreshAPNsToken this does NOT force a reconnect — challenge responses
    /// already carry the fresh hashes live; this only keeps future
    /// registrations consistent.
    internal var modelWeightHashOverrides: [String: String] = [:]

    internal var shutdownRequested = false

    /// Mutable advertised-model list. Seeded from `config.models`; background
    /// prefetch (Layer 3) appends newly-verified builds so re-registration and
    /// reconnects pick them up without dropping the currently-served model.
    internal let advertisedModelStore: AdvertisedModelStore

    public init(
        config: CoordinatorClientConfig,
        stats: AtomicProviderStats,
        state: ProviderState,
        liveAPNsToken: (@Sendable () -> String?)? = nil
    ) {
        self.config = config
        self.stats = stats
        self.state = state
        self.advertisedModelStore = AdvertisedModelStore(config.models)
        self.liveAPNsToken = liveAPNsToken ?? { APNsBridge.shared.currentDeviceToken() }
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
//
// Named uniquely (not `Logger`) and `internal` so the actor's `logger` property
// can be internal for the in-module split without shadowing `Logging.Logger` /
// `os.Logger` elsewhere in the module.

#if canImport(os)
internal typealias CoordinatorWSLogger = os.Logger
#else
internal struct CoordinatorWSLogger {
    let subsystem: String
    let category: String

    func info(_ msg: String) { print("[\(category)] INFO: \(msg)") }
    func warning(_ msg: String) { print("[\(category)] WARN: \(msg)") }
    func error(_ msg: String) { print("[\(category)] ERROR: \(msg)") }
}
#endif
