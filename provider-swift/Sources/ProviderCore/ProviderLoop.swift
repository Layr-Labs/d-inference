/// ProviderLoop -- the main event loop that ties all subsystems together.
///
/// Owns the CoordinatorClient, BatchScheduler, NodeKeyPair, and
/// SecureEnclaveIdentity. Processes coordinator events: inference requests,
/// cancellations, attestation challenges, and connection lifecycle.
///
/// Each inference request spawns its own Task for concurrent processing.
/// The BatchScheduler manages admission control and model loading.
/// Responses are encrypted with the consumer's ephemeral public key
/// and streamed back through the coordinator.

import CryptoKit
import Foundation
import MLXLMServer
#if canImport(os)
import os
#endif

// MARK: - SendHandle (Sendable wrapper for the coordinator send function)

/// Wraps the coordinator's outbound send function so it can be captured in
/// Tasks and closures that require `Sendable`. The underlying function is
/// thread-safe (it yields into an `AsyncStream.Continuation`) but its type
/// signature from `CoordinatorClient.start()` does not carry `@Sendable`.
public final class SendHandle: @unchecked Sendable {
    private let fn: (OutboundMessage) -> Void
    /// Direct inference-chunk fast path (bypasses the AsyncStream control path).
    /// `nil` for SendHandles built without a wired coordinator (unit/integration
    /// tests), in which case chunks fall back to the control path.
    private let chunkSender: ChunkSender?

    public init(_ fn: @escaping (OutboundMessage) -> Void) {
        self.fn = fn
        self.chunkSender = nil
    }

    /// Wire the direct chunk path alongside the control path. Internal: the
    /// production wiring lives in `ProviderLoop+Serve` (same module); the public
    /// init keeps the existing test/call surface unchanged.
    init(_ fn: @escaping (OutboundMessage) -> Void, chunkSender: ChunkSender?) {
        self.fn = fn
        self.chunkSender = chunkSender
    }

    /// Control-path send (heartbeats, attestation, accepted, complete, errors,
    /// model/prefetch status) through the OutboundRouter → AsyncStream.
    ///
    /// Doubles as the ORDERING BARRIER for the direct path: before a TERMINAL
    /// inference message (`inference_complete` / `inference_error`) goes out the
    /// slower control path, any chunks queued on the direct path are flushed to
    /// the wire first. The coordinator `RemovePending`s on complete, so a
    /// terminal that overtook a chunk would make it drop the chunk's tail.
    public func send(_ message: OutboundMessage) {
        switch message {
        case .inferenceComplete, .inferenceError:
            chunkSender?.flush()
        default:
            break
        }
        fn(message)
    }

    /// Inference-chunk hot path. Encodes + writes the frame directly to the live
    /// NWConnection via the ChunkSender (no actor hop, no AsyncStream, no
    /// cooperative-pool scheduling gap). Falls back to the control path when no
    /// direct sender is wired (tests) or encoding fails.
    public func sendChunk(_ message: OutboundMessage) {
        if let chunkSender, chunkSender.sendChunk(message) {
            return
        }
        fn(message)
    }
}

/// Bridges a `SendHandle` to the `PrefetchStatusSink` contract so the prefetch
/// coordinator can emit status without depending on `OutboundMessage`/transport
/// types (keeps it independently testable with a recording sink).
struct SendHandlePrefetchSink: PrefetchStatusSink {
    let send: SendHandle
    func emit(
        modelId: String,
        status: ProviderMessage.PrefetchModelStatus.Status,
        bytesDone: Int64,
        bytesTotal: Int64,
        error: String?
    ) {
        send.send(.prefetchModelStatus(
            modelId: modelId,
            status: status,
            bytesDone: bytesDone,
            bytesTotal: bytesTotal,
            error: error
        ))
    }
}

/// Wraps a `PrefetchStatusSink` and additionally notifies the host on terminal
/// `.failed` statuses. `ProviderLoop` uses this to schedule a bounded-backoff
/// retry when a DESIRED build's background prefetch fails (one transient
/// network/CDN error must not strand the provider on the old build until the
/// next coordinator push — the resume-aware downloader makes a retry cheap).
struct RetryNotifyingPrefetchSink: PrefetchStatusSink {
    let base: any PrefetchStatusSink
    let onFailed: @Sendable (String) -> Void
    func emit(
        modelId: String,
        status: ProviderMessage.PrefetchModelStatus.Status,
        bytesDone: Int64,
        bytesTotal: Int64,
        error: String?
    ) {
        base.emit(modelId: modelId, status: status, bytesDone: bytesDone, bytesTotal: bytesTotal, error: error)
        if status == .failed {
            onFailed(modelId)
        }
    }
}

internal final class OneShotBoolContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: Bool) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

internal enum ProviderLoopError: Error, CustomStringConvertible {
    case binaryHashUnavailable

    var description: String {
        switch self {
        case .binaryHashUnavailable:
            return "provider binary hash could not be computed"
        }
    }
}

// MARK: - ProviderLoop

// Access note: the actor's stored state and many of its methods are declared
// `internal` rather than `private` so this actor can be split by concern across
// the companion `ProviderLoop+*.swift` files in this module (Swift `private` is
// file-scoped). Only members actually reached across that split are widened;
// purely-local members (e.g. `configuredMaxModelSlots`, `bytesPerGiB`,
// `createAttestationSigner`) stay `private`. Behavior is unchanged.
public actor ProviderLoop {
    internal let loopConfig: ProviderLoopConfig
    internal let keyPair: NodeKeyPair
    internal let signer: (any AttestationSigner)?
    internal let attestationBuilder: AttestationBuilder?
    internal let stats: AtomicProviderStats
    internal let state: ProviderState
    internal let cancellationRegistry: InferenceCancellationRegistry
    internal let kvBudget: GlobalKVCacheBudget
    /// Phase 3: global disk accountant (process-wide, shared across models).
    internal let diskAccountant: GlobalDiskAccountant
    internal let powerAssertion: InferencePowerAssertion
    internal let preloadTaskStarted: (@Sendable (String) -> Void)?
    internal let beforeModelLoad: (@Sendable (String) async -> Void)?

    /// Per-model inference slots. Each loaded model gets its own
    /// BatchScheduler and worker task. Keyed by model ID.
    internal var modelSlots: [String: ModelSlot] = [:]

    /// ContinuousBatchingV2 bridge registry consulted by the capacity and
    /// cancellation hooks — but ONLY when at least one v2 slot exists (see
    /// the `hasEngineV2Slots` guards in `ProviderLoop+Capacity` /
    /// `+Cancellation`), so flag-off providers never pay the actor hop.
    /// Defaults to the process-global instance; tests inject an isolated one.
    internal var engineV2Runtime: EngineV2Runtime = .shared

    /// Test seam (`ProviderLoop+Testing`): overrides the environment, the
    /// container EOS snapshot, and the production CBv2 engine builder used
    /// by `makeEngineV2BridgeForSlot`. nil in production.
    internal var engineV2SlotHooks: EngineV2SlotHooks?

    /// Operator-configured hard cap on concurrent model slots
    /// (`backend.maxModelSlots`). This is the memory-safety ceiling: the
    /// effective cap never exceeds it. A provider configured with `1` has opted
    /// out of concurrency and stays single-slot regardless of how many builds
    /// it advertises.
    private let configuredMaxModelSlots: Int

    /// Number of de-duplicated models advertised at startup. The effective cap
    /// never drops below this, so a provider that booted advertising N models
    /// can always hold those N resident (subject to the configured hard cap).
    private let startupModelCount: Int

    /// Effective concurrent-slot cap. Tracks the LIVE advertised-model count
    /// rather than freezing it at startup, so a verified prefetch that adds a
    /// new build (via `applyVerifiedPrefetch`) lets the provider hold old+new
    /// resident concurrently during a zero-downtime migration. Always clamped
    /// to `[1, configuredMaxModelSlots]` and floored at `startupModelCount`.
    /// Read by the slot-cap guards as the current cap.
    internal var maxModelSlots: Int {
        let live = max(startupModelCount, advertisedModels.count)
        return max(1, min(configuredMaxModelSlots, live))
    }

    /// Maps request IDs to the model they're running on, so the idle
    /// monitor knows which model has in-flight work.
    internal var requestToModel: [String: String] = [:]

    /// Per-model count of in-flight requests from the LOCAL HTTP endpoint
    /// (unified mode), used to keep eviction and the idle monitor from pulling a
    /// model out from under a local stream. See `LocalReservationCounter`.
    internal var localReservations = LocalReservationCounter()

    /// The running local OpenAI HTTP server task (unified mode), if any.
    internal var localServerTask: Task<Void, Never>?

    /// Guards against concurrent loads. `modelsLoading` tracks which models
    /// are mid-load; waiters suspend until the first loader finishes.
    /// `isLoadingAny` serializes loads so two large models don't interleave
    /// eviction decisions and overcommit memory.
    internal var loadingWaiters: [String: [CheckedContinuation<Void, any Error>]] = [:]
    internal var modelsLoading: Set<String> = []
    internal var loadGateWaiters: [CheckedContinuation<Void, Never>] = []
    /// Distinct model commitments queued behind the global load gate. Counts
    /// preserve duplicate callers while capacity reports the dictionary keys.
    internal var loadGateWaitingModels: [String: Int] = [:]
    internal var isLoadingAny: Bool = false
    internal var isShuttingDown: Bool = false

    /// Phase of a graceful auto-update cycle. Drives admission: in `.draining`
    /// we refuse new requests (503 reroute) so in-flight work can finish before
    /// the hot-swap restart. See `AutoUpdateController`.
    ///   - `.idle`:       normal serving (no update in progress)
    ///   - `.installing`: a newer release is downloading/staging; STILL serving
    ///   - `.draining`:   bundle staged; refusing new requests while in-flight
    ///                    work finishes, then commit + restart
    internal enum UpdatePhase: Sendable, Equatable {
        case idle
        case installing
        case draining
    }
    internal var updatePhase: UpdatePhase = .idle

    /// Verified update bundle staged on disk during `.installing`, awaiting the
    /// post-drain commit. The live layout is untouched until the commit, so a
    /// request can never observe a half-replaced bundle. Consumed by
    /// `commitStagedUpdateBundle`; discarded by `resumeServingAfterUpdate`.
    internal var stagedUpdateBundle: SelfUpdater.StagedBundle?

    /// Latest `desired_models` push received while update-draining. Normally
    /// the restart makes it moot (registration gets fresh desired state), but
    /// if the restart is aborted (commit/restart failure) the deferred state
    /// is replayed by `resumeServingAfterUpdate` so the provider does not keep
    /// serving from a desired set the coordinator has since changed.
    internal var deferredDesiredModels: [CoordinatorMessage.DesiredModelEntry]?

    /// Models remain tracked while their scheduler is tearing down so
    /// reentrant loads cannot start against memory that has not been freed yet.
    internal var modelsUnloading: Set<String> = []
    internal var unloadingWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// Tracks in-flight inference tasks by request ID so they can be cancelled.
    internal var inflightTasks: [String: Task<Void, Never>] = [:]

    /// A detached task can finish before the actor stores it in `inflightTasks`.
    /// Track that edge so the post-spawn registration does not leave a stale task.
    internal var completedBeforeTaskRegistration = Set<String>()

    /// Mutable advertised-model set, seeded from `loopConfig.models`. Background
    /// prefetch appends newly-verified builds at runtime so they become
    /// loadable/servable and appear in the local `/v1/models` catalog without a
    /// restart. Keyed by model id; never drops the currently-served model. The
    /// `CoordinatorClient` keeps its own mirror (`AdvertisedModelStore`) for the
    /// registration wire path; these are kept in sync via `advertiseModel`.
    internal var advertisedModels: [String: ModelInfo]

    /// Mutable model weight-hash map, seeded from `loopConfig.modelHashes`.
    /// Background prefetch records the verified build's weight hash here so the
    /// attestation challenge response (`active_model_hash` / `model_hashes`) and
    /// `syncWarmModelState` cover hotswapped models — otherwise the coordinator's
    /// per-model hash verification would be silently bypassed for them. Keyed by
    /// model id; weight hashes are immutable per build (a model id maps to one
    /// verified snapshot).
    internal var modelHashes: [String: String]

    /// Pending hard swaps: desired build id → the previous build to retire locally
    /// once the desired one verifies. Populated by the declarative `desired_models`
    /// reconcile, consumed (once) in `applyVerifiedPrefetch`.
    internal var desiredSwapDrop: [String: String] = [:]

    /// Desired builds from the latest declarative reconcile. If a build was once
    /// desired but disappears from a later desired set while its prefetch is still
    /// in flight, a late verified callback for that old build is ignored.
    internal var desiredPrefetchTargets = Set<String>()
    internal var staleDesiredPrefetches = Set<String>()

    /// Priority used for desired-build convergence prefetches (reconcile +
    /// retry), between an explicit coordinator `prefetch_model` default and
    /// urgent operator pushes.
    static let desiredModelsPrefetchPriority = 5

    /// Bounded-backoff retry state for failed DESIRED-build prefetches. One
    /// transient download failure must not strand the provider on the old build
    /// until an operator re-POSTs the alias: each failure of a still-desired
    /// build schedules one retry per delay below, then gives up until the next
    /// desired_models push (which resets the budget). Delays are injectable for
    /// tests via `setDesiredPrefetchRetryDelaysForTesting`.
    internal var desiredPrefetchRetryDelays: [Duration] = [
        .seconds(30), .seconds(60), .seconds(120), .seconds(300), .seconds(600),
    ]
    internal var desiredPrefetchRetryAttempts: [String: Int] = [:]
    internal var desiredPrefetchRetryTasks: [String: Task<Void, Never>] = [:]

    /// Background model-build prefetcher. Owns coalescing, throttled progress,
    /// cancellation, and the verified→advertise hook (which also performs the
    /// hard-swap drop of the superseded build). Built lazily in `run()` so it can
    /// capture `self` and the live coordinator client.
    internal var prefetchCoordinator: ModelPrefetchCoordinator?

    /// The live coordinator client, retained so the verified-prefetch hook can
    /// re-register the updated advertised set, and so weight-hash refreshes can be
    /// pushed into reconnect registrations (models[].weight_hash drives the
    /// coordinator's per-model catalog routing filter). Set in `run()`.
    internal var coordinatorClient: CoordinatorClient?

    /// The live outbound send handle (same one prefetch status flows through).
    /// Retained so `applyVerifiedPrefetch` can push an out-of-band
    /// `models_update` carrying the verified build's authoritative `ModelInfo`
    /// (including its computed weight hash) for the coordinator to cross-check
    /// before routing. Set in `run()`; injectable in tests via
    /// `installPrefetchCoordinatorForTesting`.
    internal var outboundSend: SendHandle?

    /// Tracks coordinator-driven preload tasks so they can be cancelled on shutdown.
    internal var preloadTasks: [String: Task<Void, Never>] = [:]

    /// Startup preload driver (`ProviderLoop+StartupPreload`). Non-nil while
    /// the boot-time preload of the configured/previously-served model set is
    /// still running — it may outlive the registration gate when the
    /// `startup_preload_timeout_secs` deadline passes (loads continue in the
    /// background). Cancelled and awaited on shutdown alongside the
    /// coordinator-driven preloads.
    internal var startupPreloadTask: Task<Void, Never>?

    /// Test seam: overrides the loaded-models persistence file
    /// (default: `LoadedModelsStore.path()`).
    internal var loadedModelsFileOverride: URL?

    /// Gate on the loaded-models persistence writes. `run()` flips it on at
    /// startup; it stays FALSE for `ProviderLoop` instances that never serve
    /// (unit tests exercising load/unload paths), so an unrelated test can
    /// never clobber the operator's real `~/.darkbloom/loaded-models.json`
    /// — that file is the next boot's preload plan. The test seam
    /// `setLoadedModelsFileForTesting` enables it together with a temp path.
    internal var loadedModelsPersistenceEnabled = false

    /// Test seams for the startup preload driver: replace the real
    /// `ensureModelLoaded` / self-test decode / free-memory probe with
    /// scripted stubs so the plan, gate timing, admission, and
    /// fail-open/closed paths run without model weights or a live memory
    /// reading. nil in production.
    internal var startupPreloadLoadOverride: (@Sendable (String) async throws -> Void)?
    internal var startupSelfTestOverride: (@Sendable (String) async throws -> Duration)?
    internal var startupPreloadFreeMemoryOverride: (@Sendable () async -> Double)?

    /// Senders waiting for the terminal status of an in-flight preload.
    internal var preloadStatusSubscribers: [String: [SendHandle]] = [:]

    /// Ownership tokens for preload tasks — ensures deferred cleanup only
    /// removes an entry if it still belongs to the completing task.
    internal var preloadTaskIds: [String: UUID] = [:]

    /// Cached security posture from startup verification.
    internal var securityPosture: SecurityPosture?

    /// Cached binary hash for attestation responses.
    internal var binaryHash: String?

    /// Live per-model weight hashes. Seeded from the startup scan and REFRESHED
    /// whenever a model is (re)loaded from disk, so attestation challenge
    /// responses report the weights actually being served — not the state of
    /// the disk when the daemon started. Previously the startup map was frozen
    /// for the process lifetime: a model re-published while the daemon ran kept
    /// the stale hash and tripped the coordinator's model-swap hard-untrust
    /// even though the disk (and the loaded model) were correct.
    internal var liveModelHashes: [String: String]

    /// Per-model snapshot fingerprints (paths + sizes + mtimes) recorded when a
    /// weight hash was last computed. A model whose fingerprint is unchanged at
    /// reload skips the full multi-second re-hash — idle-unload/lazy-reload
    /// cycles happen hourly, and re-reading ~30 GB of unchanged weights each
    /// time would tax cold-start TTFT for nothing. Seeded from the config so
    /// the FIRST load doesn't re-read weights already hashed at startup.
    internal var modelHashFingerprints: [String: String]

    /// Whether we've already submitted an auto-report for this session.
    /// Set to true after the first trust-triggered report to avoid spamming.
    internal var didAutoReport = false

    /// Task for the delayed auto-report (10 minutes after learning trust status).
    internal var autoReportTask: Task<Void, Never>?

    /// Diagnostics: the most recent trust_status from the coordinator and the
    /// most recent model-load failure, plus the daemon start time. Persisted to
    /// the daemon state file so `darkbloom status`/`doctor` can show the
    /// operator WHY they are / aren't earning. Start time uses wall-clock epoch
    /// (not ContinuousClock) so it survives across the CLI process boundary.
    internal var lastTrustStatus: DaemonState.Trust?
    internal var lastModelLoadError: DaemonState.ModelLoadError?
    internal let startedAtEpoch: Double = Date().timeIntervalSince1970

    /// Keeps the network stack alive during sleep for APN push notifications.
    /// Held for the entire provider session so MDM SecurityInfo commands
    /// can be delivered even when the Mac is sleeping.
    internal let networkAssertion = NetworkPowerAssertion()

    /// Background task that periodically checks idle state and unloads
    /// the model when the timeout has elapsed. nil when disabled
    /// (`idleTimeoutMins == 0`) or before `run()` starts it.
    internal var idleMonitorTask: Task<Void, Never>?

    /// Periodically refreshes provider-reported backend capacity so heartbeats
    /// reflect active/queued requests and adaptive batch-cap changes while
    /// long-running generations are still in flight.
    internal var capacityRefreshTask: Task<Void, Never>?

    /// Background task that periodically checks for provider updates and
    /// applies them automatically. nil when auto-update is disabled or
    /// before `run()` starts it.
    internal var autoUpdateTask: Task<Void, Never>?

    /// Reacts to kernel memory pressure (reclaim MLX cache, mark an imminent
    /// OOM). Held for the loop's lifetime so the DispatchSource isn't
    /// deallocated. See `MemoryPressureMonitor` / `OOMDetector`.
    internal var memoryPressureMonitor: MemoryPressureMonitor?

    internal let logger = ProviderLogger(subsystem: "dev.darkbloom.provider", category: "loop")

    internal static let shutdownDrainTimeout: Duration = .seconds(600)
    internal static let preloadShutdownTimeout: Duration = .seconds(10)
    private static let bytesPerGiB: UInt64 = 1024 * 1024 * 1024

    // MARK: - Initialization

    public init(config: ProviderLoopConfig) throws {
        try self.init(
            config: config,
            purgeLegacyFiles: true,
            attestationSigner: Self.createAttestationSigner()
        )
    }

    init(
        config: ProviderLoopConfig,
        purgeLegacyFiles: Bool,
        attestationSigner: (any AttestationSigner)?,
        preloadTaskStarted: (@Sendable (String) -> Void)? = nil,
        beforeModelLoad: (@Sendable (String) async -> Void)? = nil
    ) throws {
        self.loopConfig = config
        var advertised: [String: ModelInfo] = [:]
        for model in config.models where advertised[model.id] == nil {
            advertised[model.id] = model
        }
        self.advertisedModels = advertised
        self.modelHashes = config.modelHashes
        if purgeLegacyFiles {
            NodeKeyPair.purgeLegacyFiles()
        }
        self.keyPair = NodeKeyPair.generate()
        self.signer = attestationSigner
        self.attestationBuilder = signer.map { AttestationBuilder(identity: $0) }
        self.stats = AtomicProviderStats()
        self.state = ProviderState()
        self.cancellationRegistry = InferenceCancellationRegistry()
        // The effective cap (`maxModelSlots`) is computed from the live
        // advertised set; here we capture the operator hard cap and the
        // de-duplicated startup count it is clamped against. Using the deduped
        // `advertised.count` (not raw `config.models.count`) keeps the startup
        // floor consistent with what is actually advertised.
        self.configuredMaxModelSlots = max(1, Int(config.config.backend.maxModelSlots))
        self.startupModelCount = max(1, advertised.count)
        // KV budget derives its ceiling from the unified 90% cap + activation
        // reserve (UnifiedMemoryCap). It ALSO honors the operator-configured
        // `memory_reserve_gb` — the same reserve the model LOAD gate applies
        // (loadReserveBytes = max(configReserve, physical − cap)) — so runtime KV
        // can't grow into memory the operator explicitly reserved once a model is
        // loaded. No-op when the configured reserve is ≤ the cap's implied reserve.
        self.kvBudget = GlobalKVCacheBudget(
            configReserveBytes: Self.memoryReserveBytes(forGiB: config.config.provider.memoryReserveGB))
        // Phase 3: construct the global disk accountant (one per host).
        let kvRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("darkbloom/kv", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("darkbloom/kv")
        self.diskAccountant = GlobalDiskAccountant(
            kvRoot: kvRoot,
            configuredCeiling: BatchScheduler.prefixCacheGlobalDiskCeiling(),
            sweepOnInit: true)  // wipe stale KV from a prior crash before any load
        self.powerAssertion = InferencePowerAssertion(reason: "Darkbloom inference job active")
        self.preloadTaskStarted = preloadTaskStarted
        self.beforeModelLoad = beforeModelLoad
        self.liveModelHashes = config.modelHashes
        self.modelHashFingerprints = config.modelHashFingerprints
    }

    static func memoryReserveBytes(forGiB gb: UInt64) -> UInt64 {
        let (bytes, overflow) = gb.multipliedReportingOverflow(by: bytesPerGiB)
        return overflow ? UInt64.max : bytes
    }

    // MARK: - Model Slot

    internal static let schedulerMaxConcurrent = 24
    internal static let schedulerPendingTimeout: Duration = .seconds(120)
    internal static let schedulerDefaultMaxTokens = 4096

    /// Infer the reasoning parser format from the model's `model_type`
    /// (read from config.json at scan time). Used to auto-select the
    /// parser when the consumer doesn't specify one.
    static func inferReasoningParser(for modelType: String?) -> ReasoningParserFormat {
        guard let type = modelType?.lowercased() else { return .qwen3 }
        if type == "gpt_oss" { return .harmony }
        if type.hasPrefix("gemma") { return .gemma4 }
        if type.hasPrefix("qwen") { return .qwen3 }
        if type.hasPrefix("deepseek") { return .deepseekR1 }
        // Safe default: qwen3's <think> parser handles the most common format.
        return .qwen3
    }

    internal struct ModelSlot {
        let scheduler: BatchScheduler
        /// ContinuousBatchingV2 bridge for this slot — non-nil ONLY when
        /// `EngineV2Config` selected the v2 engine at load time AND its
        /// construction succeeded. Stored ALONGSIDE (never replacing) the
        /// legacy scheduler: requests route through the bridge when present,
        /// and every fallback path (flag off, non-allowlisted model, v2 init
        /// failure) leaves this nil and serves via `scheduler` unchanged.
        let engineV2: EngineV2Bridge?
        let container: MLXLMCommon.ModelContainer
        let tokenizer: TokenizerHandle
        /// Vision-language model (config has `vision_config`). Multimodal
        /// requests are served from `container` via the non-batched path.
        let isVLM: Bool
        /// Model type (e.g. "gemma"), captured at load. Authoritative for the
        /// reasoning-parser choice for as long as the model can serve — read
        /// this, NOT `advertisedModels[id]`, which goes nil in the hard-swap
        /// drop window while the slot is still resident (a Gemma build would
        /// otherwise fall back to the qwen3 parser and leak <think> tokens).
        let modelType: String?
        var lastInferenceAt: ContinuousClock.Instant
    }

    /// Try persistent keychain-backed SE key first; fall back to ephemeral CryptoKit key.
    private static func createAttestationSigner() -> (any AttestationSigner)? {
        let log = ProviderLogger(subsystem: "dev.darkbloom.provider", category: "loop")

        if PersistentEnclaveKey.isAvailable {
            do {
                // loadOrCreateVerified proves the key can actually sign (and
                // auto-repairs a poisoned/locked key once) before we commit to
                // it. A key that loads but can't sign would otherwise fail every
                // attestation challenge silently and pin the box untrusted.
                let key = try PersistentEnclaveKey.loadOrCreateVerified()
                log.info("Using persistent keychain-backed Secure Enclave key for attestation")
                return key
            } catch {
                log.warning("Persistent SE key unavailable or unusable (\(error)), falling back to ephemeral")
            }
        }

        do {
            return try SecureEnclaveIdentity.createEphemeral()
        } catch {
            log.warning("Ephemeral SE identity also unavailable: \(error)")
            return nil
        }
    }

    // MARK: - Companion files
    //
    // This actor is split by concern across same-module extension files. This
    // core file holds only the type declaration, stored state, init, the
    // `ModelSlot`/static config, and the nested helper types above.
    //
    //   - ProviderLoop+Serve.swift               run() loop + registration setup
    //   - ProviderLoop+InferenceHandler.swift    handleInferenceRequest + draining gates
    //   - ProviderLoop+Preload.swift             load_model preload + preload/shutdown waits
    //   - ProviderLoop+StartupPreload.swift      boot-time preload + registration readiness gate
    //   - ProviderLoop+Prefetch.swift            background prefetch + desired-models reconcile
    //   - ProviderLoop+Testing.swift             test-only seams (ProviderCoreTests)
    //   - ProviderLoop+Trust.swift               trust status + one-time auto-report
    //   - ProviderLoop+MemoryProtection.swift    OOM surfacing + memory-pressure
    //   - ProviderLoop+IdleTimeout.swift         idle-timeout model unload
    //   - ProviderLoop+Capacity.swift            capacity refresh + updateAggregateCapacity
    //   - ProviderLoop+AutoUpdate.swift          background self-update + phase transitions
    //   - ProviderLoop+ModelLoading.swift        ensureModelLoaded/unload + memory admission
    //   - ProviderLoop+EngineV2.swift            ContinuousBatchingV2 slot wiring (flag-gated)
    //   - ProviderLoop+Cancellation.swift        cancellation + in-flight drain
    //   - ProviderLoop+AttestationChallenge.swift attestation + APNs code challenge
    //   - ProviderLoop+LocalEndpoint.swift       unified local HTTP endpoint
    //   - ProviderLoop+SSEParser.swift           StreamChunkExtract, parseStreamChunk, encodeToolCallsForHash
    //   - ProviderLoop+ErrorMapping.swift        mapInferenceErrorToStatus
    //   - ProviderLoop+InboundDecode.swift       decodeOpenAIRequest (see InboundChatNormalization)
}

// MARK: - Import bridge

import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
