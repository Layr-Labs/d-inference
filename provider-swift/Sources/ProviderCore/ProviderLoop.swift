/// Coordinator-facing supervisor event loop.
///
/// Owns transport, update/download control, and Secure Enclave attestation.
/// Inference ciphertext is forwarded to the authenticated sandboxed XPC worker;
/// this actor owns no process private key or inference plaintext.

import CryptoKit
import Foundation
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
        case .privateChunkV2(let chunk) where chunk.terminal:
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

    /// Worker-frame forwarding barrier. Production chunks are acknowledged to
    /// the XPC worker only after Network.framework completes the corresponding
    /// send; the test/control fallback acknowledges after synchronous consumer
    /// handoff.
    public func sendChunkAwaitingTransport(_ message: OutboundMessage) async throws {
        if let chunkSender {
            guard await chunkSender.sendChunkAwaitingTransport(message) else {
                throw InferenceWorkerClientError.connectionFailed
            }
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
    let onFailed: @Sendable (String, String?) -> Void
    func emit(
        modelId: String,
        status: ProviderMessage.PrefetchModelStatus.Status,
        bytesDone: Int64,
        bytesTotal: Int64,
        error: String?
    ) {
        base.emit(modelId: modelId, status: status, bytesDone: bytesDone, bytesTotal: bytesTotal, error: error)
        if status == .failed {
            onFailed(modelId, error)
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
    case inferenceWorkerBeforeHardening
    case inferenceWorkerConfigurationInvalid

    var description: String {
        switch self {
        case .binaryHashUnavailable:
            return "provider binary hash could not be computed"
        case .inferenceWorkerBeforeHardening:
            return "inference worker launch attempted before security hardening"
        case .inferenceWorkerConfigurationInvalid:
            return "inference worker configuration is invalid"
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
    internal let inferenceWorkerClient: InferenceWorkerClient
    internal var inferenceWorkerIdentity: InferenceWorkerProcessIdentity?
    internal var inferenceWorkerRuntimeCapabilities =
        Set<ProviderRuntimeCapability>()
    internal var securityHardeningCompleted = false
    internal let signer: (any AttestationSigner)?
    internal let attestationBuilder: AttestationBuilder?
    internal let stats: AtomicProviderStats
    internal let state: ProviderState
    internal let preloadTaskStarted: (@Sendable (String) -> Void)?
    internal var inflightTasks: [String: Task<Void, Never>] = [:]
    internal var completedBeforeTaskRegistration = Set<String>()

    internal var updateLifecycle = try! UpdateLifecycleReconciler()
    internal var updateLifecycleStore = UpdateLifecycleStore()
    internal var updateAdmissionClosed = false
    internal var coordinatorConnectionGeneration: UInt64 = 0
    internal var evidenceSentConnectionGeneration: UInt64?
    internal var certifiedConnectionGeneration: UInt64?
    internal var pendingCertifiedConnectionGeneration: UInt64?
    internal var updateLifecycleStateCorrupt = false
    internal var updateWarmRestoreInProgress = false
    internal var stagedUpdateBundle: SelfUpdater.StagedBundle?
    internal var updateSession: SelfUpdater.UpdateSession?
    internal var deferredDesiredModels = DeferredDesiredModelsBuffer()
    internal var desiredModelGeneration: UInt64 = 0

    internal var advertisedModels: [String: ModelInfo]
    internal var modelHashes: [String: String]
    internal var desiredSwapDrop: [String: String] = [:]
    internal var desiredPrefetchTargets = Set<String>()
    internal var staleDesiredPrefetches = Set<String>()
    static let desiredModelsPrefetchPriority = 5
    internal var desiredPrefetchRetryDelays: [Duration] = [
        .seconds(30), .seconds(60), .seconds(120), .seconds(300), .seconds(600),
    ]
    internal var desiredPrefetchRetryAttempts: [String: Int] = [:]
    internal var desiredPrefetchRetryTasks: [String: Task<Void, Never>] = [:]
    internal var prefetchCoordinator: ModelPrefetchCoordinator?
    internal var coordinatorClient: CoordinatorClient?
    internal var outboundSend: SendHandle?

    internal var preloadTasks: [String: Task<Void, Never>] = [:]
    internal var startupPreloadTask: Task<Void, Never>?
    internal var startupPreloadGateCompleted = false
    internal var preloadStatusSubscribers: [String: [SendHandle]] = [:]
    internal var preloadTaskIds: [String: UUID] = [:]
    internal var isShuttingDown = false

    internal var loadedModelsFileOverride: URL?
    internal var daemonStateFileOverride: URL?
    internal var loadedModelsPersistenceEnabled = false
    internal var startupPreloadLoadOverride:
        (@Sendable (String) async throws -> Void)?
    internal var startupPreloadFreeMemoryOverride:
        (@Sendable () async -> Double)?

    internal var securityPosture: SecurityPosture?
    internal var binaryHash: String?
    internal var liveModelHashes: [String: String]
    internal var modelHashFingerprints: [String: String]
    internal var lastTrustStatus: DaemonState.Trust?
    internal var lastModelLoadError: DaemonState.ModelLoadError?
    internal var lastLiveSlotPostures:
        [DaemonSlotPostureBuilder.LiveSlot] = []
    internal let startedAtEpoch = Date().timeIntervalSince1970
    internal let networkAssertion = NetworkPowerAssertion()
    internal var capacityRefreshTask: Task<Void, Never>?
    internal let logger = ProviderLogger(
        subsystem: "dev.darkbloom.provider", category: "loop")

    internal static let shutdownDrainTimeout: Duration = .seconds(600)
    internal static let preloadShutdownTimeout: Duration = .seconds(10)

    public init(config: ProviderLoopConfig) throws {
        try self.init(
            config: config,
            purgeLegacyFiles: true,
            attestationSigner: Self.createAttestationSigner())
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
        _ = purgeLegacyFiles
        _ = beforeModelLoad
        self.inferenceWorkerClient = InferenceWorkerClient()
        self.inferenceWorkerIdentity = nil
        self.signer = attestationSigner
        self.attestationBuilder = attestationSigner.map {
            AttestationBuilder(identity: $0)
        }
        self.stats = AtomicProviderStats()
        self.state = ProviderState()
        self.preloadTaskStarted = preloadTaskStarted
        self.liveModelHashes = config.modelHashes
        self.modelHashFingerprints = config.modelHashFingerprints
    }

    private static func createAttestationSigner()
        -> (any AttestationSigner)?
    {
        let log = ProviderLogger(
            subsystem: "dev.darkbloom.provider", category: "loop")
        if PersistentEnclaveKey.isAvailable {
            do {
                let key = try PersistentEnclaveKey.loadOrCreateVerified()
                log.info(
                    "Using persistent keychain-backed Secure Enclave key "
                        + "for attestation")
                return key
            } catch {
                log.warning(
                    "Persistent Secure Enclave key unavailable; "
                        + "using ephemeral identity")
            }
        }
        do {
            return try SecureEnclaveIdentity.createEphemeral()
        } catch {
            log.warning("Secure Enclave identity unavailable")
            return nil
        }
    }
}
