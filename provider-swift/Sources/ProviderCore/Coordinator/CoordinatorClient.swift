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
    /// can be several MiB. Applied to the connection via
    /// `NWProtocolWebSocket.Options.maximumMessageSize` at setup (see
    /// `connectAndRun`): a larger frame is rejected by the transport, which tears
    /// down the entire session and cancels every unrelated in-flight request on this
    /// provider (then reconnects with backoff). Size this comfortably above the
    /// coordinator's 16 MiB sealed-body cap after base64 expansion (×4/3 ≈ 21.3 MiB).
    static let maxInboundMessageBytes = 32 * 1024 * 1024

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

    /// Inference-chunk fast path. `chunkBatcher` owns the dedicated serial queue
    /// + coalescing; `chunkSender` is the nonisolated, Sendable handle the
    /// ProviderLoop captures so `emitSSE` can write chunks straight to the live
    /// NWConnection — bypassing the OutboundRouter → AsyncStream → for-await
    /// control path (whose cooperative-pool consumer is starved by MLX decode).
    /// Both are `nonisolated` so the hot path never hops to this actor. The
    /// batcher's connection sink is (re)bound per session in `connectAndRun`;
    /// control messages (heartbeats, attestation, complete/error) keep flowing
    /// through `outboundRouter`.
    nonisolated internal let chunkBatcher: ChunkBatcher
    nonisolated internal let chunkSender: ChunkSender

    /// Active Network.framework WebSocket connection (replaces the prior
    /// `URLSessionWebSocketTask`). Outbound frames are written with the
    /// non-blocking `NWConnection.send`, which buffers in the kernel and returns
    /// immediately instead of `await`-ing each TCP ACK — that is what unblocks
    /// per-stream inference-chunk throughput under concurrent load.
    internal var nwConnection: NWConnection?

    /// Serial queue that drives the NWConnection state machine, receive
    /// callbacks, send completions, and pong handlers. Kept off the cooperative
    /// pool and the actor executor. `internal` (not `private`) because the
    /// connection extension in `CoordinatorClient+Connection.swift` starts the
    /// connection and registers the pong handler on it (Swift `private` is
    /// file-scoped, and this actor is split across files).
    internal let connectionQueue = DispatchQueue(label: "dev.darkbloom.coordinator.nw")
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

    private let shutdownFlag = ShutdownFlag()

    /// Fast, thread-safe shutdown visibility for connection tasks.
    ///
    /// The outbound WebSocket writer checks this once per inference chunk. Keep
    /// the read nonisolated so the hot path does not hop back to the
    /// CoordinatorClient actor just to read a Bool.
    nonisolated internal var shutdownRequested: Bool {
        shutdownFlag.isRequested
    }

    /// Set when a graceful shutdown drain has begun. The socket stays open so
    /// in-flight responses can finish, but the `ProviderLoop` event stream is no
    /// longer being consumed — so the inbound dispatch rejects NEW inference
    /// requests with 503 (instead of yielding them into an unconsumed stream) so
    /// the coordinator reroutes them immediately. See `beginDraining()`.
    /// `internal` (not `private`): read by the inbound/connection extensions
    /// (Swift `private` is file-scoped, and this actor is split across files).
    internal var draining = false

    /// Cancel handler installed by `beginDraining`. While draining (the event
    /// stream is no longer consumed), inbound dispatch routes coordinator
    /// `cancel` frames straight here so an aborted in-flight request still stops
    /// generating instead of running until the drain timeout.
    internal var drainCancelHandler: (@Sendable (String) async -> Void)?

    /// Disconnect handler installed by `beginDraining`. If the socket drops while
    /// draining (event stream no longer consumed), the coordinator fails our
    /// in-flight requests, so this lets the provider cancel them rather than keep
    /// generating frames that can never reach the consumer.
    internal var drainDisconnectHandler: (@Sendable () async -> Void)?

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

        // Inference-chunk fast path. The encode closure is the same pure static
        // codec the control path uses; on the (effectively impossible) encode
        // failure of a fixed-shape chunk it returns nil so SendHandle falls back
        // to the control path. A local logger is captured (not `self.logger`,
        // which isn't available while initializing stored properties) to avoid a
        // retain cycle through the actor.
        let chunkLogger = CoordinatorWSLogger(
            subsystem: "dev.darkbloom.provider", category: "coordinator.chunks")
        let batcher = ChunkBatcher()
        self.chunkBatcher = batcher
        self.chunkSender = ChunkSender(batcher: batcher, encode: { message in
            do {
                return try CoordinatorClientCodec.encodeOutboundMessage(message)
            } catch {
                chunkLogger.error("chunk encode failed: \(error.localizedDescription)")
                TelemetryClient.shared.emit(
                    kind: .protocolError,
                    severity: .error,
                    message: "outbound chunk encode failed",
                    fields: ["error": .string(error.localizedDescription)]
                )
                return nil
            }
        })
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
        shutdownFlag.request()
        closeCurrentConnection()
        eventContinuation?.finish()
        outboundRouter.finish()
    }

    /// Enter draining mode: keep the connection open (so in-flight responses can
    /// still be delivered) but reject NEW inference requests with 503 from the
    /// inbound dispatch. Used during a graceful stop/restart, when the
    /// `ProviderLoop` event stream is no longer consuming events but the drain
    /// has not finished.
    ///
    /// - Parameters:
    ///   - onCancel: invoked for coordinator `cancel` frames received while
    ///     draining, so an aborted in-flight request stops generating promptly
    ///     instead of running until the drain timeout.
    ///   - onDisconnect: invoked if the socket drops while draining, so the
    ///     provider can cancel in-flight work the coordinator has already failed
    ///     instead of generating frames that can no longer be delivered.
    public func beginDraining(
        onCancel: (@Sendable (String) async -> Void)? = nil,
        onDisconnect: (@Sendable () async -> Void)? = nil
    ) {
        draining = true
        drainCancelHandler = onCancel
        drainDisconnectHandler = onDisconnect
    }

    /// Wait until queued outbound control messages have been handed to the
    /// transport, or `timeout` elapses. Used during a graceful drain so the tail
    /// of a finished request (its final `inference_complete`) is delivered
    /// before the transport is torn down by `shutdown()`. Inference chunks ride
    /// the direct fast path and are flushed ahead of every terminal by
    /// `SendHandle.send`'s ordering barrier, so waiting on the control path
    /// covers the whole response.
    public func flushOutbound(timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while outboundRouter.pendingCount() > 0 {
            if ContinuousClock.now >= deadline {
                logger.warning("Outbound flush timed out with \(self.outboundRouter.pendingCount()) message(s) still queued")
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Handle a socket drop that happens while draining: the coordinator fails
    /// our in-flight requests on disconnect, so cancel them (don't keep
    /// generating undeliverable frames) and stop reconnecting. Called by the
    /// reconnect loop in `CoordinatorClient+Connection`.
    internal func handleDrainDisconnect() async {
        logger.info("Coordinator socket closed during drain; cancelling in-flight work and stopping reconnects")
        // Nothing yielded after this point can ever be delivered (the reconnect
        // loop is stopping), so tear down outbound delivery now. This zeroes the
        // router's pending-write count — otherwise a terminal sent by a settling
        // request would strand `flushOutbound` for its full timeout.
        outboundRouter.finish()
        if let handler = drainDisconnectHandler { await handler() }
    }

    /// Send a WebSocket close frame (going-away) on the current connection and
    /// then tear it down. Mirrors the old
    /// `URLSessionWebSocketTask.cancel(with: .goingAway, reason: nil)`: a clean
    /// close lets the coordinator deregister us promptly instead of waiting out a
    /// ping/pong timeout. `cancel()` runs in the send completion so the close
    /// frame is handed to the transport first. Used both for permanent shutdown
    /// and for the APNs-refresh forced reconnect (the reconnect loop re-runs
    /// registration while `shutdownRequested` is still false). Fire-and-forget:
    /// the actor is not blocked waiting for the frame to flush.
    private func closeCurrentConnection() {
        guard let connection = nwConnection else { return }
        nwConnection = nil
        // Best-effort close frame: enqueue a .goingAway close frame so the
        // coordinator sees a clean WS shutdown. Then cancel immediately —
        // don't gate on the close frame flushing, because if the connection is
        // still handshaking, the write side is wedged, or the peer is
        // unreachable, the completion handler never fires and cancel() never
        // runs, leaving the connection (and its reconnect-blocking state) alive.
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .protocolCode(.goingAway)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        connection.send(
            content: nil,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { _ in }
        )
        connection.cancel()
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
        closeCurrentConnection()
    }

    /// Tear down the current connection (clean close frame) WITHOUT setting
    /// `shutdownRequested`, so the reconnect loop re-runs `sendRegistration`
    /// with the CURRENT advertised set. Used when the advertised set SHRINKS
    /// after registration (e.g. a startup self-test retirement under
    /// `startup_selftest_fail_closed`): `models_update` is additive, so a
    /// fresh `register` is the existing wire mechanism that communicates a
    /// removal. Same reconnect path the coordinator handles on any network
    /// blip; no-op when no connection is up (registration hasn't happened
    /// yet — the register that follows will already carry the current set).
    public func forceReconnect() {
        closeCurrentConnection()
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
