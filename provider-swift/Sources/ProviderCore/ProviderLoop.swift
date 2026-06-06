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

    public init(_ fn: @escaping (OutboundMessage) -> Void) {
        self.fn = fn
    }

    public func send(_ message: OutboundMessage) {
        fn(message)
    }
}

private final class OneShotBoolContinuation: @unchecked Sendable {
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

private enum ProviderLoopError: Error, CustomStringConvertible {
    case binaryHashUnavailable

    var description: String {
        switch self {
        case .binaryHashUnavailable:
            return "provider binary hash could not be computed"
        }
    }
}

// MARK: - Configuration

public struct ProviderLoopConfig: Sendable {
    public let coordinatorURL: String
    public let hardware: HardwareInfo
    public let models: [ModelInfo]
    public let config: ProviderConfig
    public let authToken: String?
    public let runtimeHashes: RuntimeHashes?
    public let modelHashes: [String: String]
    /// When set, the provider also serves a local OpenAI-compatible HTTP
    /// endpoint off the SAME loaded models it serves to the coordinator
    /// (unified mode). nil = coordinator-only (the default).
    public let localEndpoint: LocalInferenceHTTPConfig?

    public init(
        coordinatorURL: String,
        hardware: HardwareInfo,
        models: [ModelInfo],
        config: ProviderConfig,
        authToken: String? = nil,
        runtimeHashes: RuntimeHashes? = nil,
        modelHashes: [String: String] = [:],
        localEndpoint: LocalInferenceHTTPConfig? = nil
    ) {
        self.coordinatorURL = coordinatorURL
        self.hardware = hardware
        self.models = models
        self.config = config
        self.authToken = authToken
        self.runtimeHashes = runtimeHashes
        self.modelHashes = modelHashes
        self.localEndpoint = localEndpoint
    }
}

// MARK: - ProviderLoop

public actor ProviderLoop {
    private let loopConfig: ProviderLoopConfig
    private let keyPair: NodeKeyPair
    private let signer: (any AttestationSigner)?
    private let attestationBuilder: AttestationBuilder?
    private let stats: AtomicProviderStats
    private let state: ProviderState
    private let cancellationRegistry: InferenceCancellationRegistry
    private let kvBudget: GlobalKVCacheBudget
    private let powerAssertion: InferencePowerAssertion
    private let preloadTaskStarted: (@Sendable (String) -> Void)?
    private let beforeModelLoad: (@Sendable (String) async -> Void)?

    /// Per-model inference slots. Each loaded model gets its own
    /// BatchScheduler and worker task. Keyed by model ID.
    private var modelSlots: [String: ModelSlot] = [:]

    /// Hard cap on concurrent model slots to prevent coordinator-driven OOM.
    private let maxModelSlots: Int

    /// Maps request IDs to the model they're running on, so the idle
    /// monitor knows which model has in-flight work.
    private var requestToModel: [String: String] = [:]

    /// Per-model count of in-flight requests from the LOCAL HTTP endpoint
    /// (unified mode), used to keep eviction and the idle monitor from pulling a
    /// model out from under a local stream. See `LocalReservationCounter`.
    private var localReservations = LocalReservationCounter()

    /// The running local OpenAI HTTP server task (unified mode), if any.
    private var localServerTask: Task<Void, Never>?

    /// Guards against concurrent loads. `modelsLoading` tracks which models
    /// are mid-load; waiters suspend until the first loader finishes.
    /// `isLoadingAny` serializes loads so two large models don't interleave
    /// eviction decisions and overcommit memory.
    private var loadingWaiters: [String: [CheckedContinuation<Void, any Error>]] = [:]
    private var modelsLoading: Set<String> = []
    private var loadGateWaiters: [CheckedContinuation<Void, Never>] = []
    private var isLoadingAny: Bool = false
    private var isShuttingDown: Bool = false

    /// Models remain tracked while their scheduler is tearing down so
    /// reentrant loads cannot start against memory that has not been freed yet.
    private var modelsUnloading: Set<String> = []
    private var unloadingWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// Tracks in-flight inference tasks by request ID so they can be cancelled.
    private var inflightTasks: [String: Task<Void, Never>] = [:]

    /// A detached task can finish before the actor stores it in `inflightTasks`.
    /// Track that edge so the post-spawn registration does not leave a stale task.
    private var completedBeforeTaskRegistration = Set<String>()

    /// Tracks coordinator-driven preload tasks so they can be cancelled on shutdown.
    private var preloadTasks: [String: Task<Void, Never>] = [:]

    /// Senders waiting for the terminal status of an in-flight preload.
    private var preloadStatusSubscribers: [String: [SendHandle]] = [:]

    /// Ownership tokens for preload tasks — ensures deferred cleanup only
    /// removes an entry if it still belongs to the completing task.
    private var preloadTaskIds: [String: UUID] = [:]

    /// Cached security posture from startup verification.
    private var securityPosture: SecurityPosture?

    /// Cached binary hash for attestation responses.
    private var binaryHash: String?

    /// Whether we've already submitted an auto-report for this session.
    /// Set to true after the first trust-triggered report to avoid spamming.
    private var didAutoReport = false

    /// Task for the delayed auto-report (10 minutes after learning trust status).
    private var autoReportTask: Task<Void, Never>?

    /// Diagnostics: the most recent trust_status from the coordinator and the
    /// most recent model-load failure, plus the daemon start time. Persisted to
    /// the daemon state file so `darkbloom status`/`doctor` can show the
    /// operator WHY they are / aren't earning. Start time uses wall-clock epoch
    /// (not ContinuousClock) so it survives across the CLI process boundary.
    private var lastTrustStatus: DaemonState.Trust?
    private var lastModelLoadError: DaemonState.ModelLoadError?
    private let startedAtEpoch: Double = Date().timeIntervalSince1970

    /// Keeps the network stack alive during sleep for APN push notifications.
    /// Held for the entire provider session so MDM SecurityInfo commands
    /// can be delivered even when the Mac is sleeping.
    private let networkAssertion = NetworkPowerAssertion()

    /// Background task that periodically checks idle state and unloads
    /// the model when the timeout has elapsed. nil when disabled
    /// (`idleTimeoutMins == 0`) or before `run()` starts it.
    private var idleMonitorTask: Task<Void, Never>?

    /// Periodically refreshes provider-reported backend capacity so heartbeats
    /// reflect active/queued requests and adaptive batch-cap changes while
    /// long-running generations are still in flight.
    private var capacityRefreshTask: Task<Void, Never>?

    /// Background task that periodically checks for provider updates and
    /// applies them automatically. nil when auto-update is disabled or
    /// before `run()` starts it.
    private var autoUpdateTask: Task<Void, Never>?

    private let logger = ProviderLogger(subsystem: "dev.darkbloom.provider", category: "loop")

    private static let shutdownDrainTimeout: Duration = .seconds(600)
    private static let preloadShutdownTimeout: Duration = .seconds(10)
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
        if purgeLegacyFiles {
            NodeKeyPair.purgeLegacyFiles()
        }
        self.keyPair = NodeKeyPair.generate()
        self.signer = attestationSigner
        self.attestationBuilder = signer.map { AttestationBuilder(identity: $0) }
        self.stats = AtomicProviderStats()
        self.state = ProviderState()
        self.cancellationRegistry = InferenceCancellationRegistry()
        self.maxModelSlots = max(1, min(config.models.count, Int(config.config.backend.maxModelSlots)))
        let reserveBytes = Self.memoryReserveBytes(forGiB: config.config.provider.memoryReserveGB)
        self.kvBudget = GlobalKVCacheBudget(reserveBytes: reserveBytes)
        self.powerAssertion = InferencePowerAssertion(reason: "Darkbloom inference job active")
        self.preloadTaskStarted = preloadTaskStarted
        self.beforeModelLoad = beforeModelLoad
    }

    static func memoryReserveBytes(forGiB gb: UInt64) -> UInt64 {
        let (bytes, overflow) = gb.multipliedReportingOverflow(by: bytesPerGiB)
        return overflow ? UInt64.max : bytes
    }

    // MARK: - Model Slot

    private static let schedulerMaxConcurrent = 24
    private static let schedulerPendingTimeout: Duration = .seconds(120)
    private static let schedulerDefaultMaxTokens = 4096

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

    private struct ModelSlot {
        let scheduler: BatchScheduler
        let container: MLXLMCommon.ModelContainer
        let tokenizer: TokenizerHandle
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

    // MARK: - Main Run Loop

    public func run() async throws {
        logger.info("darkbloom \(ProviderCore.version) starting")
        logger.info("Hardware: \(loopConfig.hardware.chipName), \(loopConfig.hardware.memoryGb) GB RAM, \(loopConfig.hardware.gpuCores) GPU cores")
        logger.info("Models: \(loopConfig.models.count) advertised")
        logger.info("Coordinator: \(loopConfig.coordinatorURL)")

        // Keep the network stack alive during sleep for APN/MDM push delivery.
        networkAssertion.acquire()
        defer { networkAssertion.release() }

        // Unified mode: also expose a local OpenAI endpoint off the same loaded
        // models. Started before the coordinator connection so local clients can
        // serve immediately; torn down on shutdown.
        if let localEndpoint = loopConfig.localEndpoint {
            startLocalEndpoint(localEndpoint)
        }
        defer { stopLocalEndpoint() }

        // 1. Apply security hardening
        try await applySecurityHardening()

        // 2. Build attestation blob for registration
        let attestation = buildRegistrationAttestation()

        // 3. Hash the colocated mlx.metallib so the coordinator (and any
        // user inspecting attestation) can correlate the GPU kernel set
        // with the binary. Reported under template_hashes["mlx_metallib"]
        // so legacy providers and Swift providers can keep one protocol
        // shape while the coordinator applies backend-specific enforcement.
        let runtimeWithMetallib = augmentRuntimeHashesWithMetallib(loopConfig.runtimeHashes)
        if let metallib = runtimeWithMetallib?.templateHashes["mlx_metallib"] {
            logger.info("mlx.metallib hash: \(metallib.prefix(16))...")
        } else {
            logger.warning("mlx.metallib not found near binary -- inference will fail at first GPU call")
        }

        // 4. Create coordinator client config
        let coordinatorConfig = CoordinatorClientConfig(
            url: loopConfig.coordinatorURL,
            hardware: loopConfig.hardware,
            models: loopConfig.models,
            backendName: "mlx-swift",
            heartbeatInterval: TimeInterval(loopConfig.config.coordinator.heartbeatIntervalSecs),
            publicKey: keyPair.publicKeyBase64,
            walletAddress: nil,
            attestation: attestation,
            authToken: loopConfig.authToken,
            runtimeHashes: runtimeWithMetallib,
            modelHashes: loopConfig.modelHashes,
            privacyCapabilities: privacyCapabilitiesForRegistration(),
            privateOnly: loopConfig.config.coordinator.privateOnly
        )

        // 4. Create coordinator client and start connection
        let coordinator = CoordinatorClient(
            config: coordinatorConfig,
            stats: stats,
            state: state
        )

        let (events, sendFn) = await coordinator.start()
        let send = SendHandle(sendFn)

        // Start the idle-timeout monitor before processing events so that
        // a rogue model-load (e.g. during `attestation_challenge` priming)
        // followed by a long disconnect is still subject to the unload
        // timer.
        startIdleMonitor()
        startCapacityRefreshMonitor()
        startAutoUpdateMonitor()

        logger.info("Coordinator client started, entering event loop")

        // 5. Process events. Cancellation is used by schedule enforcement
        // and service shutdown; explicitly close the WebSocket so the stream
        // unblocks instead of waiting for the next coordinator event.
        await withTaskCancellationHandler {
            for await event in events {
                switch event {
                case .connected:
                    logger.info("Connected to coordinator")

                case .disconnected:
                    logger.warning("Disconnected from coordinator")
                    // Cancel all in-flight requests on disconnect -- the coordinator
                    // will not route responses for a dead connection.
                    await cancelAllInflight()

                case .inferenceRequest(let requestId, let ciphertext, let senderPublicKey):
                    await handleInferenceRequest(
                        requestId: requestId,
                        ciphertext: ciphertext,
                        senderPublicKey: senderPublicKey,
                        send: send
                    )

                case .cancel(let requestId):
                    await handleCancellation(requestId: requestId)

                case .attestationChallenge(let nonce, let timestamp):
                    await handleAttestationChallenge(
                        nonce: nonce,
                        timestamp: timestamp,
                        send: send
                    )

                case .runtimeOutdated(let mismatches):
                    logger.warning("Runtime outdated: \(mismatches.count) mismatch(es)")
                    for m in mismatches {
                        logger.warning("  \(m.component): expected=\(m.expected), got=\(m.got)")
                    }

                case .loadModel(let modelId):
                    handleLoadModelRequest(modelId: modelId, send: send)

                case .trustStatus(let trustLevel, let status, let reason):
                    handleTrustStatus(trustLevel: trustLevel, status: status, reason: reason)
                }
            }
        } onCancel: {
            Task { await coordinator.shutdown() }
        }

        logger.info("Event stream ended, shutting down")
        isShuttingDown = true
        idleMonitorTask?.cancel()
        idleMonitorTask = nil
        capacityRefreshTask?.cancel()
        capacityRefreshTask = nil
        autoUpdateTask?.cancel()
        autoUpdateTask = nil
        autoReportTask?.cancel()
        autoReportTask = nil
        let preloads = Array(preloadTasks.values)
        for task in preloads { task.cancel() }
        cancelLoadWaiters()
        let preloadsFinished = await waitForPreloads(preloads, timeout: Self.preloadShutdownTimeout)
        if !preloadsFinished {
            logger.warning("Timed out waiting for coordinator-driven preloads to cancel during shutdown")
        }
        preloadTasks.removeAll()
        preloadTaskIds.removeAll()
        preloadStatusSubscribers.removeAll()

        let drained = await waitForInflightDrain(timeout: Self.shutdownDrainTimeout)
        if !drained {
            logger.warning("Timed out waiting for active inference to drain; cancelling remaining requests")
            await cancelAllInflight()
        }
        await coordinator.shutdown()
        while !modelSlots.isEmpty {
            if let unloading = modelsUnloading.first {
                await waitForModelUnload(unloading)
                continue
            }
            for modelId in Array(modelSlots.keys) {
                await unloadModel(modelId)
            }
        }
        powerAssertion.releaseAll()
    }

    // MARK: - Security Hardening

    private func applySecurityHardening() async throws {
        #if !DEBUG
        let posture = try verifySecurityPosture()
        guard let binaryHash = posture.binaryHash, !binaryHash.isEmpty else {
            logger.error("Security hardening failed: provider binary hash unavailable")
            throw ProviderLoopError.binaryHashUnavailable
        }
        self.securityPosture = posture
        self.binaryHash = binaryHash
        logger.info("Security posture verified: SIP=\(posture.sipEnabled), RDMA_disabled=\(posture.rdmaDisabled), SE=\(SecureEnclave.isAvailable)")
        #else
        logger.info("Security hardening skipped in DEBUG mode")
        self.binaryHash = selfBinaryHash()
        #endif
    }

    private func privacyCapabilitiesForRegistration() -> PrivacyCapabilities {
        // textBackendInprocess + textProxyDisabled: always true on the Swift
        //   provider -- inference runs in-process via mlx-swift-lm, no HTTP
        //   proxy is involved.
        // pythonRuntimeLocked + dangerousModulesBlocked: report false. There
        //   is no Python runtime to lock anymore. Coordinator's Swift-runtime
        //   trust path (registry.BackendUsesSwiftRuntime) doesn't read these.
        // hypervisorActive: false -- Hypervisor.framework Stage 2 page tables
        //   were dropped at the migration; trust is RDMA discipline + SE
        //   attestation.
        if let posture = securityPosture {
            return PrivacyCapabilities(
                textBackendInprocess: true,
                textProxyDisabled: true,
                pythonRuntimeLocked: false,
                dangerousModulesBlocked: false,
                sipEnabled: posture.sipEnabled,
                antiDebugEnabled: posture.antiDebugEnabled,
                coreDumpsDisabled: posture.coreDumpsDisabled,
                envScrubbed: posture.envScrubbed,
                hypervisorActive: false
            )
        }

        // Pre-hardening fallback (DEBUG builds, or hardening failed).
        return PrivacyCapabilities(
            textBackendInprocess: true,
            textProxyDisabled: true,
            pythonRuntimeLocked: false,
            dangerousModulesBlocked: false,
            sipEnabled: SecurityChecks.isSIPEnabled(),
            antiDebugEnabled: false,
            coreDumpsDisabled: false,
            envScrubbed: false,
            hypervisorActive: false
        )
    }

    // MARK: - Runtime hashes

    /// Add the live mlx.metallib hash under template_hashes["mlx_metallib"]
    /// while preserving any caller-supplied template entries. Returns nil if
    /// the input was nil and no metallib could be located (so we don't
    /// fabricate an empty RuntimeHashes that would suppress legitimate
    /// nil-handling downstream).
    private func augmentRuntimeHashesWithMetallib(
        _ existing: RuntimeHashes?
    ) -> RuntimeHashes? {
        let metallib = metallibHash()

        // No metallib and no caller-supplied data -- return whatever the
        // caller passed (might be nil; that's fine).
        if metallib == nil, existing == nil {
            return nil
        }

        var templates = existing?.templateHashes ?? [:]
        if let metallib {
            templates["mlx_metallib"] = metallib
        }

        return RuntimeHashes(
            pythonHash: existing?.pythonHash,
            runtimeHash: existing?.runtimeHash,
            templateHashes: templates
        )
    }

    // MARK: - Attestation

    private func buildRegistrationAttestation() -> RawJSON? {
        guard let builder = attestationBuilder else {
            logger.info("No Secure Enclave identity -- registration without attestation")
            return nil
        }
        do {
            let jsonData = try builder.buildAttestationJSON(
                encryptionPublicKey: keyPair.publicKeyBase64,
                binaryHash: binaryHash
            )
            return RawJSON(rawBytes: jsonData)
        } catch {
            logger.error("Failed to build attestation: \(error)")
            return nil
        }
    }

    // MARK: - Inference Request Handling

    private func handleInferenceRequest(
        requestId: String,
        ciphertext: Data,
        senderPublicKey: Data?,
        send: SendHandle
    ) async {
        logger.info("Processing inference request: \(requestId)")

        if isShuttingDown {
            send.send(.inferenceError(
                requestId: requestId,
                error: "provider is shutting down",
                statusCode: 503
            ))
            return
        }

        // 1. Decrypt the request body. Both `ciphertext` and
        // `senderPublicKey` are already base64-decoded by CoordinatorClient,
        // so we hand the raw bytes straight to NodeKeyPair.decrypt.
        guard let senderKey = senderPublicKey, senderKey.count == 32 else {
            logger.error("[\(requestId)] missing or malformed sender public key")
            send.send(.inferenceError(
                requestId: requestId,
                error: "missing or malformed ephemeral_public_key",
                statusCode: 400
            ))
            return
        }

        let decryptedData: Data
        do {
            decryptedData = try keyPair.decrypt(
                senderPublicKey: senderKey,
                ciphertext: ciphertext
            )
        } catch {
            logger.error("[\(requestId)] decryption failed: \(error)")
            send.send(.inferenceError(
                requestId: requestId,
                error: "decryption failed",
                statusCode: 400
            ))
            return
        }

        // 2. Parse the chat completion request into the upstream
        // `OpenAIChatCompletionRequest` shape. `decodeOpenAIRequest`
        // strict-decodes on the fast path and, on failure, normalises a
        // few valid-but-strictly-rejected OpenAI shapes (hosted/custom
        // tools, content-less messages, the `developer` role) before
        // retrying — surfacing the real decoder error on failure rather
        // than a masked one (#252). See ProviderLoop+InboundDecode.swift.
        let chatRequest: OpenAIChatCompletionRequest
        do {
            chatRequest = try Self.decodeOpenAIRequest(decryptedData)
        } catch {
            logger.error("[\(requestId)] Failed to parse chat request: \(error)")
            send.send(.inferenceError(requestId: requestId, error: "invalid request body: \(error.localizedDescription)", statusCode: 400))
            return
        }

        // `reasoning_effort` is not part of the upstream
        // `OpenAIChatCompletionRequest` shape, so decode it directly from
        // the request body and thread it into the chat template's render
        // context below (see `MultiModelBatchSchedulerEngine`). gpt-oss /
        // Harmony reads it to set the reasoning budget; other models
        // ignore the extra template variable.
        let reasoningEffort = Self.extractReasoningEffort(from: decryptedData)

        // 3. Fast pre-accept admission check. The coordinator accepts fast and
        // then waits for the first chunk with the full inference timeout, so we
        // must REJECT (status 503) any request we are *certain* we cannot serve
        // — letting the coordinator reroute — rather than accept-then-fail,
        // which it counts as a provider fault (reputation penalty). This mirrors
        // the real load-failure conditions WITHOUT loading anything and is
        // deliberately conservative: when in doubt it admits and lets the
        // post-accept load path below make the final call.
        let modelId = chatRequest.model
        if await fastAdmissionReject(modelId: modelId) {
            logger.warning("[\(requestId)] Pre-accept reject for '\(modelId)': insufficient capacity to load")
            send.send(.inferenceError(
                requestId: requestId,
                error: "insufficient memory to load model '\(modelId)'",
                statusCode: 503
            ))
            return
        }

        // 4. Send inference_accepted
        send.send(.inferenceAccepted(requestId: requestId))

        // 5. Mark the request before loading so concurrent preloads cannot
        // evict the model this accepted request is waiting for.
        requestToModel[requestId] = modelId
        powerAssertion.acquire()
        syncWarmModelState()
        let token = await cancellationRegistry.register(requestId: requestId)

        // 6. Ensure model is loaded. The fast check above only rules out
        // certain failures; this stays authoritative for races (e.g. another
        // request consuming the last slot or free memory between accept and
        // load). Map the failure to a status code so capacity errors reroute
        // (503) and missing models 404 instead of always counting as a fault.
        do {
            try await ensureModelLoaded(modelId: modelId)
        } catch {
            if requestToModel.removeValue(forKey: requestId) != nil {
                powerAssertion.release()
                syncWarmModelState()
                await updateAggregateCapacity()
            }
            await cancellationRegistry.finish(requestId: requestId)
            logger.error("[\(requestId)] Failed to load model '\(modelId)': \(error)")
            let statusCode = Self.loadErrorStatusCode(for: error)
            send.send(.inferenceError(requestId: requestId, error: "model load failed: \(error.localizedDescription)", statusCode: statusCode))
            return
        }

        guard requestToModel[requestId] == modelId else {
            await cancellationRegistry.finish(requestId: requestId)
            logger.info("[\(requestId)] Request cancelled during model load")
            return
        }

        guard let slot = modelSlots[modelId] else {
            if requestToModel.removeValue(forKey: requestId) != nil {
                powerAssertion.release()
                syncWarmModelState()
                await updateAggregateCapacity()
            }
            await cancellationRegistry.finish(requestId: requestId)
            logger.error("[\(requestId)] Model '\(modelId)' disappeared after load")
            send.send(.inferenceError(requestId: requestId, error: "model unavailable", statusCode: 500))
            return
        }

        modelSlots[modelId]?.lastInferenceAt = .now
        syncWarmModelState()

        // 7. Capture values for the spawned task
        let responsePublicKeyData: Data = senderKey
        let kp = self.keyPair
        let sched = slot.scheduler
        let providerStats = self.stats
        let registry = self.cancellationRegistry
        let signingIdentity = self.signer
        let log = self.logger
        let tokenizer = slot.tokenizer
        let modelType = loopConfig.models.first(where: { $0.id == modelId })?.modelType

        // 8. Spawn inference task. The streaming pipeline now flows through
        // the upstream `MLXLMServer` library:
        //   - `MultiModelBatchSchedulerEngine` adapts our `BatchScheduler` to
        //     the `MLXServerEngine` contract.
        //   - `MLXOpenAIService.streamChatCompletionFrames` formats SSE
        //     frames (matching the wire shape the coordinator already parses).
        // We encrypt each frame and forward it via `inferenceChunk` exactly
        // as before. The response hash for SE attestation is computed over
        // the assembled assistant text, extracted by parsing each emitted
        // chunk back from its JSON delta.
        let me = self
        let task = Task.detached {
            defer {
                Task {
                    await registry.finish(requestId: requestId)
                    await me.finishInflightRequest(requestId: requestId)
                }
            }

            /// Encrypts and emits an SSE frame string. Returns `false` if
            /// encryption failed — callers must abort the inference task
            /// immediately.
            let emitSSE: @Sendable (String) -> Bool = { sseData in
                let encryptedPayload: EncryptedPayload
                do {
                    encryptedPayload = try kp.encryptPayload(
                        recipientPublicKey: responsePublicKeyData,
                        plaintext: Data(sseData.utf8)
                    )
                } catch {
                    log.error("[\(requestId)] Chunk encryption failed: \(error)")
                    send.send(.inferenceError(
                        requestId: requestId,
                        error: "response encryption failed",
                        statusCode: 500
                    ))
                    return false
                }

                send.send(.inferenceChunk(
                    requestId: requestId,
                    data: "",
                    encryptedData: encryptedPayload
                ))
                return true
            }

            // Build a single-model engine view bound to the scheduler we
            // already resolved. This keeps the engine constructor's
            // "model not loaded" path unreachable on this code path while
            // still going through the upstream library for SSE encoding.
            let providerEngine = MultiModelBatchSchedulerEngine(
                registryProvider: { @Sendable in
                    [chatRequest.model: .init(scheduler: sched, tokenizer: tokenizer, modelType: modelType)]
                },
                ensureLoaded: { _ in },
                reserveModel: { _ in },
                releaseModel: { _ in },
                defaultMaxTokens: Self.schedulerDefaultMaxTokens,
                reasoningEffort: reasoningEffort
            )

            // Force-stream so we get SSE frames even if the original request
            // had `stream: false`. The coordinator always uses streaming
            // chunks on the wire today; non-streaming consumers reassemble
            // on their end.
            //
            // Also force `streamOptions.includeUsage = true`. Without it,
            // upstream's `MLXOpenAIService.streamChatCompletionFrames` will
            // not emit the trailing usage chunk (see
            // `libs/mlx-swift-lm/Libraries/MLXLMServer/Runtime/MLXOpenAIService.swift`
            // line 88: `let includeUsage = request.streamOptions?.includeUsage == true`).
            // Missing usage means `parseStreamChunk` never extracts
            // `promptTokens`/`completionTokens`, and the coordinator bills
            // $0 for the request. This is the C1 fix.
            var streamingRequest = chatRequest
            streamingRequest.stream = true
            var forcedStreamOptions = streamingRequest.streamOptions
                ?? OpenAIStreamOptions()
            forcedStreamOptions.includeUsage = true
            streamingRequest.streamOptions = forcedStreamOptions

            // Auto-select reasoning parser based on model type if the
            // consumer didn't specify one. This ensures model-specific
            // reasoning tokens (Harmony channels, Gemma4 channels,
            // Qwen3/DeepSeek <think> tags) are parsed into
            // reasoning_content rather than leaking as raw content.
            if streamingRequest.reasoningParser == nil {
                streamingRequest.reasoningParser = Self.inferReasoningParser(for: modelType)
            }

            let service = MLXOpenAIService(engine: providerEngine)
            let frames: AsyncThrowingStream<String, Error>
            do {
                frames = try await service.streamChatCompletionFrames(
                    request: streamingRequest
                )
            } catch {
                log.error("[\(requestId)] Failed to start stream: \(error)")
                let statusCode = Self.mapInferenceErrorToStatus(error)
                send.send(.inferenceError(
                    requestId: requestId,
                    error: error.localizedDescription,
                    statusCode: statusCode
                ))
                return
            }

            await me.updateAggregateCapacity()

            var fullResponseText = ""
            var promptTokens = 0
            var completionTokens = 0
            // Defense-in-depth for the billing-zero leak: count SSE frames that
            // carried visible output. If the usage chunk is lost entirely
            // (parser drift / upstream regression), this is a conservative
            // lower-bound floor for completion tokens so a request that clearly
            // produced output never settles at 0 (which the coordinator would
            // fully refund). MLX streams ~1 token per frame, so this slightly
            // under-counts vs. true tokenization but never bills $0 for work.
            var contentFrameCount = 0
            // Accumulated `reasoning_content` deltas (gpt-oss analysis
            // channel, Qwen3/DeepSeek <think>, Gemma4 channels). Re-tokenized
            // at completion to report an accurate `reasoning_tokens` count —
            // upstream's usage block only carries the total completion count.
            var reasoningText = ""
            var reasoningTokens = 0

            do {
                for try await frame in frames {
                    if token.isCancelled {
                        log.info("[\(requestId)] Cancelled during generation")
                        send.send(.inferenceError(
                            requestId: requestId,
                            error: "request cancelled",
                            statusCode: 499
                        ))
                        return
                    }
                    // Aggregate the assistant text + usage by parsing each
                    // chunk back from its JSON delta. This is the cost of
                    // routing through `streamChatCompletionFrames` instead
                    // of the raw engine event stream — but the alternative
                    // is duplicating SSE encoding logic.
                    //
                    // TB-007: hash domain = content + reasoning_content + tool_calls (canonicalized).
                    // - `content` and `reasoning_content` are concatenated
                    //   verbatim so the hash matches the engine's emitted
                    //   bytes (and what the consumer reassembles after SSE
                    //   parsing). When `reasoning_parser` is set, upstream
                    //   splits `<think>...</think>` blocks into the
                    //   `reasoning_content` delta field, so hashing only
                    //   the visible `content` would commit to a different
                    //   set of bytes than what the engine produced.
                    // - `tool_calls` are folded in via
                    //   `encodeToolCallsForHash(_:)` (P2 #2). Tool-calling
                    //   responses often carry empty `content` with the
                    //   real assistant output on `delta.tool_calls`; a
                    //   hash that ignored them would commit to (near-)
                    //   empty bytes instead of the actual output.
                    var frameToEmit = frame
                    if let parsed = Self.parseStreamChunk(frame) {
                        var frameHadContent = false
                        if let content = parsed.contentDelta {
                            fullResponseText += content
                            // Count only NON-empty content toward the billing
                            // floor: parseStreamChunk returns a non-nil but empty
                            // contentDelta for SSE frames carrying "content":""
                            // (role/terminal deltas), which produce no visible
                            // output and must not be billed.
                            if !content.isEmpty {
                                frameHadContent = true
                            }
                        }
                        if let reasoning = parsed.reasoningDelta, !reasoning.isEmpty {
                            fullResponseText += reasoning
                            frameHadContent = true
                            reasoningText += reasoning
                        }
                        if let toolCalls = parsed.toolCallsDelta, !toolCalls.isEmpty {
                            fullResponseText += Self.encodeToolCallsForHash(toolCalls)
                            frameHadContent = true
                        }
                        if frameHadContent {
                            contentFrameCount += 1
                        }
                        if let usage = parsed.usage {
                            promptTokens = usage.promptTokens
                            completionTokens = usage.completionTokens
                            // The usage block rides the final chunk, after all
                            // reasoning deltas, so `reasoningText` is complete
                            // here. Re-tokenize it for an accurate count and
                            // surface it to chat-completions consumers via
                            // `usage.completion_tokens_details.reasoning_tokens`
                            // (OpenAI shape). The coordinator forwards this
                            // chunk verbatim, so no coordinator change is
                            // needed for the streaming path.
                            if !reasoningText.isEmpty {
                                // Re-tokenizing detokenized text isn't a perfect
                                // identity (whitespace/special-token merges), so
                                // clamp to the engine's completion count — a
                                // reasoning subset can never exceed the total.
                                reasoningTokens = min(
                                    tokenizer.inner.encode(
                                        text: reasoningText, addSpecialTokens: false
                                    ).count,
                                    max(0, completionTokens)
                                )
                                frameToEmit = Self.injectReasoningTokens(
                                    into: frame, reasoningTokens: reasoningTokens
                                )
                            }
                        }
                    }
                    if !emitSSE(frameToEmit) { return }
                }
            } catch {
                // P1 #2: CancellationError raised by `try await
                // frame in frames` when the inflight task is cancelled
                // BEFORE the explicit `token.isCancelled` early-exit
                // branch runs. Map to 499 (Client Closed Request) so
                // the coordinator forwards an accurate status to the
                // consumer instead of a spurious 500. Mirrors the
                // shape of the `token.isCancelled` branch above.
                if error is CancellationError {
                    log.info("[\(requestId)] Cancelled while waiting on next frame")
                    send.send(.inferenceError(
                        requestId: requestId,
                        error: "request cancelled",
                        statusCode: 499
                    ))
                    return
                }
                log.error("[\(requestId)] Generation error: \(error)")
                let statusCode = Self.mapInferenceErrorToStatus(error)
                send.send(.inferenceError(
                    requestId: requestId,
                    error: error.localizedDescription,
                    statusCode: statusCode
                ))
                return
            }

            // C1 defense-in-depth: if the usage chunk somehow never landed
            // (upstream regression, parser drift, etc.) the coordinator
            // would bill $0 for this request. Log at WARN, emit a
            // diagnostic line, and continue. The chunk-parse path is the
            // primary signal; if it ever stops working we want operators
            // to see the regression in logs before the revenue impact
            // shows up on the dashboard. `BatchScheduler` does not
            // currently expose per-request token counts (only aggregate
            // capacity), so we cannot fall back to engine-authoritative
            // counts here without expanding its public surface.
            if promptTokens == 0 || completionTokens == 0 {
                // Fallback: if completion tokens are missing/zero but we
                // streamed visible output, bill the observed content-frame
                // count instead of $0. This caps the revenue leak even if the
                // usage chunk is lost entirely. Prompt tokens have no in-loop
                // proxy, so a zero there is still only logged.
                if completionTokens == 0 && contentFrameCount > 0 {
                    completionTokens = contentFrameCount
                    log.warning(
                        "[\(requestId)] usage chunk missing/zero completion tokens; "
                        + "billing \(contentFrameCount) observed content frames as a floor. "
                        + "Check upstream MLXOpenAIService.streamChatCompletionFrames behavior."
                    )
                } else {
                    log.warning(
                        "[\(requestId)] CRITICAL: usage chunk missing or zero "
                        + "(promptTokens=\(promptTokens), "
                        + "completionTokens=\(completionTokens), "
                        + "contentFrames=\(contentFrameCount)). "
                        + "Billing will be undercounted. Check upstream "
                        + "MLXOpenAIService.streamChatCompletionFrames behavior."
                    )
                }
                // Surface the usage-chunk anomaly to the operator via `doctor`
                // (recorded even when the content-frame floor recovered billing,
                // since a missing/zero usage chunk is itself the signal).
                providerStats.incrementUsageGaps()
            }

            // Update stats
            providerStats.incrementRequestsServed()
            providerStats.addTokensGenerated(UInt64(max(completionTokens, 0)))

            // Update state
            await me.updateAggregateCapacity()

            // Send completion
            let attestation = computeResponseAttestation(
                identity: signingIdentity,
                requestId: requestId,
                completionTokens: UInt64(max(completionTokens, 0)),
                responseBody: fullResponseText
            )
            let usageInfo = UsageInfo(
                promptTokens: UInt64(max(0, promptTokens)),
                completionTokens: UInt64(max(0, completionTokens)),
                reasoningTokens: UInt64(max(0, reasoningTokens))
            )
            send.send(.inferenceComplete(
                requestId: requestId,
                usage: usageInfo,
                seSignature: attestation.signature,
                responseHash: attestation.hash
            ))

            log.info("[\(requestId)] Complete: \(promptTokens) prompt + \(completionTokens) completion tokens")
        }

        inflightTasks[requestId] = task
        if completedBeforeTaskRegistration.remove(requestId) != nil {
            inflightTasks.removeValue(forKey: requestId)
        }
        modelSlots[modelId]?.lastInferenceAt = .now
    }

    // MARK: - Coordinator-driven preload

    /// Handle a `load_model` request from the coordinator. The provider
    /// kicks off the load asynchronously (so the WebSocket reader stays
    /// responsive) and emits `load_model_status` outbound messages
    /// reporting `started` immediately and `succeeded`/`failed` when the
    /// load completes.
    ///
    /// If the model is already loaded, we short-circuit with
    /// `succeeded` -- the coordinator can use this as an idempotent
    /// "ensure warm" call.
    private func handleLoadModelRequest(modelId: String, send: SendHandle) {
        if isShuttingDown {
            send.send(.loadModelStatus(
                modelId: modelId,
                status: .failed,
                error: "provider is shutting down"
            ))
            return
        }

        if modelSlots[modelId] != nil, !modelsUnloading.contains(modelId) {
            logger.info("Preload for \(modelId): already loaded, replying succeeded")
            send.send(.loadModelStatus(
                modelId: modelId,
                status: .succeeded,
                error: nil
            ))
            return
        }

        if preloadTasks[modelId] != nil {
            logger.info("Preload for \(modelId): already in progress, coalescing duplicate request")
            preloadStatusSubscribers[modelId, default: []].append(send)
            send.send(.loadModelStatus(
                modelId: modelId,
                status: .started,
                error: nil
            ))
            return
        }

        preloadStatusSubscribers[modelId] = [send]
        send.send(.loadModelStatus(
            modelId: modelId,
            status: .started,
            error: nil
        ))

        let me = self
        let taskId = UUID()
        preloadTaskIds[modelId] = taskId
        preloadTaskStarted?(modelId)
        preloadTasks[modelId] = Task {
            defer { Task { await me.removePreloadTask(modelId: modelId, taskId: taskId) } }
            do {
                try await me.ensureModelLoaded(modelId: modelId)
                try Task.checkCancellation()
                let shuttingDown = await me.isProviderShuttingDown()
                guard !shuttingDown else { return }
                await me.finishPreloadTask(modelId: modelId, taskId: taskId, status: .succeeded, error: nil)
            } catch is CancellationError {
                return
            } catch {
                let message = error.localizedDescription
                await me.logPreloadFailure(modelId: modelId, error: message)
                await me.finishPreloadTask(modelId: modelId, taskId: taskId, status: .failed, error: message)
            }
        }
    }

    private func finishPreloadTask(
        modelId: String,
        taskId: UUID,
        status: ProviderMessage.LoadModelStatus.Status,
        error: String?
    ) {
        guard preloadTaskIds[modelId] == taskId else { return }
        preloadTasks.removeValue(forKey: modelId)
        preloadTaskIds.removeValue(forKey: modelId)
        let subscribers = preloadStatusSubscribers.removeValue(forKey: modelId) ?? []
        for subscriber in subscribers {
            subscriber.send(.loadModelStatus(
                modelId: modelId,
                status: status,
                error: error
            ))
        }
    }

    // MARK: - Trust Status & Auto-Report

    /// Handle a trust_status message from the coordinator. If the provider
    /// learns it is self_signed or untrusted, schedule a one-time auto-report
    /// of unified logs after 10 minutes.
    /// Assembles the current daemon state and writes it to the state file so the
    /// CLI (`status`/`doctor`) can read live state + the latest trust reason.
    /// Best-effort and cheap; safe to call from the trust handler and the
    /// periodic capacity loop.
    private func writeDaemonState() {
        let cap = state.backendCapacity
        let snapshot = DaemonState(
            pid: getpid(),
            version: ProviderCore.version,
            writtenAt: Date().timeIntervalSince1970,
            startedAt: startedAtEpoch,
            trust: lastTrustStatus,
            currentModel: state.currentModel,
            warmModels: state.warmModels,
            inferenceActive: state.inferenceActive,
            stats: DaemonState.Stats(
                requestsServed: stats.requestsServed,
                tokensGenerated: stats.tokensGenerated,
                usageGaps: stats.usageGaps
            ),
            capacity: cap.map {
                DaemonState.Capacity(
                    totalMemoryGb: $0.totalMemoryGb,
                    gpuMemoryActiveGb: $0.gpuMemoryActiveGb,
                    gpuMemoryCacheGb: $0.gpuMemoryCacheGb)
            },
            lastModelLoadError: lastModelLoadError
        )
        DaemonStateFile.write(snapshot)
    }

    /// Records a model-load failure for the diagnostics state file so the
    /// operator sees the exact "Insufficient memory …" text in `doctor`.
    private func recordModelLoadError(model: String, message: String) {
        lastModelLoadError = DaemonState.ModelLoadError(
            model: model, message: message, at: Date().timeIntervalSince1970)
        writeDaemonState()
    }

    private func handleTrustStatus(trustLevel: String, status: String, reason: String) {
        logger.info("Trust status update: level=\(trustLevel) status=\(status) reason=\(reason)")

        // Cache + persist so `darkbloom status`/`doctor` can show the operator
        // the coordinator's reason (otherwise it is only in the logs).
        lastTrustStatus = DaemonState.Trust(
            trustLevel: trustLevel, status: status, reason: reason,
            receivedAt: Date().timeIntervalSince1970)
        writeDaemonState()

        let needsReport = trustLevel == "self_signed" || status == "untrusted"
        guard needsReport, !didAutoReport else {
            // Already reported or trust is fine — cancel any pending report.
            autoReportTask?.cancel()
            autoReportTask = nil
            return
        }

        // Schedule auto-report after 10 minutes. If the provider gets
        // upgraded to hardware trust before that, the task is cancelled.
        logger.warning("Provider is \(trustLevel)/\(status) — will auto-report logs in 10 minutes")
        autoReportTask?.cancel()
        autoReportTask = Task {
            do {
                try await Task.sleep(for: .seconds(600))
            } catch {
                return // cancelled (shutdown or trust upgraded)
            }
            guard !self.didAutoReport else { return }
            self.didAutoReport = true
            await self.submitAutoReport(trustLevel: trustLevel, status: status, reason: reason)
        }
    }

    /// Collect and upload unified logs to the coordinator.
    private func submitAutoReport(trustLevel: String, status: String, reason: String) async {
        logger.info("Auto-reporting unified logs (trust=\(trustLevel), status=\(status))")

        guard let serial = macHardwareSerialNumber(), !serial.isEmpty else {
            logger.warning("Auto-report skipped: serial number unavailable")
            return
        }

        // Collect last 24 hours of unified logs for our subsystem.
        let logData: Data
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            process.arguments = [
                "show",
                "--predicate", "subsystem == \"dev.darkbloom.provider\"",
                "--style", "ndjson",
                "--info",
                "--last", "24h",
            ]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            logData = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
        } catch {
            logger.error("Auto-report: failed to collect logs: \(error)")
            return
        }

        guard !logData.isEmpty else {
            logger.warning("Auto-report: no logs found")
            return
        }

        // Cap at 10 MB.
        let cappedData = logData.count > 10 * 1024 * 1024
            ? logData.prefix(10 * 1024 * 1024)
            : logData

        // Upload to coordinator.
        let httpBase = coordinatorHTTPBase(loopConfig.coordinatorURL)
        let urlString = "\(httpBase)/v1/provider/log-report?serial=\(serial)"
        guard let url = URL(string: urlString) else {
            logger.error("Auto-report: invalid URL: \(urlString)")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(cappedData)
        request.timeoutInterval = 60

        if let token = AuthTokenStore.load() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResp = response as? HTTPURLResponse {
                if httpResp.statusCode == 201 {
                    let sizeMB = Double(cappedData.count) / 1_048_576.0
                    logger.info("Auto-report uploaded successfully (\(String(format: "%.1f", sizeMB)) MB)")
                } else {
                    logger.warning("Auto-report upload returned HTTP \(httpResp.statusCode)")
                }
            }
        } catch {
            logger.warning("Auto-report upload failed: \(error)")
        }
    }

    private func waitForPreloads(_ preloads: [Task<Void, Never>], timeout: Duration) async -> Bool {
        guard !preloads.isEmpty else { return true }
        return await withCheckedContinuation { continuation in
            let oneShot = OneShotBoolContinuation(continuation)

            Task {
                for task in preloads { await task.value }
                oneShot.resume(returning: true)
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(Int(timeout.components.seconds))) {
                oneShot.resume(returning: false)
            }
        }
    }

    private func cancelLoadWaiters() {
        for waiters in loadingWaiters.values {
            for waiter in waiters { waiter.resume(throwing: CancellationError()) }
        }
        loadingWaiters.removeAll()
        releaseLoadGateWaiters()
        for waiters in unloadingWaiters.values {
            for waiter in waiters { waiter.resume() }
        }
        unloadingWaiters.removeAll()
    }

    private func logPreloadFailure(modelId: String, error: String) {
        logger.error("Preload for \(modelId) failed: \(error)")
    }

    private func isProviderShuttingDown() -> Bool {
        isShuttingDown
    }

    /// Only remove the preload entry if it still belongs to this task,
    /// preventing a newer preload's entry from being removed by an older
    /// task's deferred cleanup.
    private func removePreloadTask(modelId: String, taskId: UUID) {
        if preloadTaskIds[modelId] == taskId {
            preloadTasks.removeValue(forKey: modelId)
            preloadTaskIds.removeValue(forKey: modelId)
            preloadStatusSubscribers.removeValue(forKey: modelId)
        }
    }

    // MARK: - Idle timeout

    /// Start the background idle-monitor task. Polls every minute; if
    /// `idleTimeoutMins` minutes have elapsed since the last inference
    /// activity AND no requests are in flight, the loaded model is
    /// unloaded to free GPU memory. The next inference request lazy-
    /// reloads it.
    ///
    /// `idleTimeoutMins == 0` disables the monitor entirely (model stays
    /// resident forever).
    private func startIdleMonitor() {
        idleMonitorTask?.cancel()
        let timeoutMinutes = loopConfig.config.backend.idleTimeoutMins
        guard timeoutMinutes > 0 else {
            logger.info("Idle-timeout disabled (idle_timeout_mins=0)")
            return
        }

        let timeout = Duration.seconds(Int64(timeoutMinutes) * 60)
        let pollInterval = Duration.seconds(60)
        let me = self
        idleMonitorTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                if Task.isCancelled { break }
                await me.tickIdleMonitor(timeout: timeout)
            }
        }
        logger.info("Idle monitor started (timeout: \(timeoutMinutes) min)")
    }

    /// Single tick: check each loaded model for idle timeout. Unloads any
    /// model that has no in-flight requests and has exceeded the timeout.
    /// Re-validates each candidate before unloading since `await unloadModel`
    /// is a suspension point that could allow new requests to arrive.
    private func tickIdleMonitor(timeout: Duration) async {
        guard !modelSlots.isEmpty else { return }

        let now = ContinuousClock.now

        var candidates: [String] = []
        let modelsWithInflight = Set(requestToModel.values)
        for (modelId, slot) in modelSlots {
            if modelsUnloading.contains(modelId) { continue }
            let elapsed = now - slot.lastInferenceAt
            let hasInflight = modelsWithInflight.contains(modelId) || hasLocalReservation(modelId)
            if IdleTimeoutPolicy.shouldUnload(
                elapsed: elapsed,
                timeout: timeout,
                hasInflight: hasInflight,
                hasLoadedModel: true
            ) {
                candidates.append(modelId)
            }
        }

        for modelId in candidates {
            let currentInflight = Set(requestToModel.values)
            guard !currentInflight.contains(modelId),
                  !hasLocalReservation(modelId),
                  !modelsUnloading.contains(modelId),
                  let slot = modelSlots[modelId] else { continue }

            let elapsed = ContinuousClock.now - slot.lastInferenceAt
            guard IdleTimeoutPolicy.shouldUnload(
                elapsed: elapsed,
                timeout: timeout,
                hasInflight: false,
                hasLoadedModel: true
            ) else { continue }

            logger.info("Idle timeout exceeded (\(formatDuration(elapsed)) since last activity); unloading \(modelId)")
            await unloadModel(modelId)
        }
    }

    private func formatDuration(_ duration: Duration) -> String {
        let seconds = duration.components.seconds
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remMinutes = minutes % 60
        return remMinutes == 0 ? "\(hours)h" : "\(hours)h\(remMinutes)m"
    }

    // MARK: - Capacity Refresh

    private func startCapacityRefreshMonitor() {
        capacityRefreshTask?.cancel()
        let heartbeatInterval = max(1, loopConfig.config.coordinator.heartbeatIntervalSecs)
        let pollInterval = Duration.seconds(Int64(max(1, heartbeatInterval / 2)))
        let me = self
        capacityRefreshTask = Task {
            // Write once immediately so `status`/`doctor` have a fresh file soon
            // after the daemon starts, before the first poll interval elapses.
            await me.writeDaemonState()
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                if Task.isCancelled { break }
                await me.updateAggregateCapacity()
                // Refresh the diagnostics state file on the same cadence so
                // `status`/`doctor` see current model, stats, and capacity.
                await me.writeDaemonState()
            }
        }
    }

    // MARK: - Background Auto-Update

    /// Initial delay before the first background update check (5 minutes).
    /// Avoids slowing down startup; lets the provider stabilize first.
    private static let autoUpdateInitialDelay: Duration = .seconds(300)

    /// Interval between subsequent update checks (30 minutes).
    private static let autoUpdateInterval: Duration = .seconds(1800)

    /// Start the background auto-update monitor. Checks the coordinator
    /// for a newer release every 30 minutes (after an initial 5-minute
    /// delay), downloads + verifies + installs the update, then performs
    /// a launchd-aware restart.
    ///
    /// The check is skipped when:
    ///   - `config.provider.autoUpdate` is false
    ///   - `DARKBLOOM_NO_UPDATE_CHECK` env var is set
    ///   - inference requests are currently active (never update mid-inference)
    ///
    /// Failures are logged at warning level and never crash the provider.
    private func startAutoUpdateMonitor() {
        autoUpdateTask?.cancel()

        guard loopConfig.config.provider.autoUpdate else {
            logger.info("Background auto-update disabled (auto_update=false)")
            return
        }
        guard ProcessInfo.processInfo.environment["DARKBLOOM_NO_UPDATE_CHECK"] == nil else {
            logger.info("Background auto-update disabled (DARKBLOOM_NO_UPDATE_CHECK set)")
            return
        }

        let coordinatorURL = loopConfig.coordinatorURL
        let me = self
        autoUpdateTask = Task.detached {
            // Wait 5 minutes before first check.
            try? await Task.sleep(for: Self.autoUpdateInitialDelay)

            while !Task.isCancelled {
                await me.performAutoUpdateCheck(coordinatorURL: coordinatorURL)
                // Sleep 30 minutes before next check.
                try? await Task.sleep(for: Self.autoUpdateInterval)
            }
        }
        logger.info("Background auto-update monitor started (initial delay: 5m, interval: 30m)")
    }

    /// Perform a single background update check + apply cycle.
    private func performAutoUpdateCheck(coordinatorURL: String) async {
        // Skip if inference is active -- never update mid-inference.
        if !requestToModel.isEmpty {
            logger.info("Auto-update check skipped: inference requests in flight")
            return
        }

        logger.info("Auto-update: checking for provider update...")
        let updater = SelfUpdater(coordinatorBaseURL: coordinatorURL)
        let result = await updater.update()

        switch result {
        case .alreadyUpToDate:
            logger.info("Auto-update: already running latest version")

        case .updated(let from, let to):
            logger.info("Auto-update: updated provider v\(from) -> v\(to), restarting...")
            do {
                try ProcessLifecycle.restartAfterUpdate()
            } catch {
                logger.warning("Auto-update: restart failed: \(error.localizedDescription)")
            }

        case .downloadFailed(let reason):
            logger.warning("Auto-update: check failed: \(reason)")

        case .hashMismatch(let expected, let got):
            logger.warning("Auto-update: bundle hash mismatch (expected \(expected), got \(got))")

        case .replaceFailed(let reason):
            logger.warning("Auto-update: install failed: \(reason)")
        }
    }

    // MARK: - Model Loading

    private func ensureModelLoaded(modelId: String) async throws {
        if isShuttingDown {
            throw CancellationError()
        }

        while modelsUnloading.contains(modelId) {
            await waitForModelUnload(modelId)
            if isShuttingDown { throw CancellationError() }
        }

        if modelSlots[modelId] != nil {
            return
        }

        if modelsLoading.contains(modelId) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                loadingWaiters[modelId, default: []].append(cont)
            }
            try Task.checkCancellation()
            if isShuttingDown { throw CancellationError() }
            while modelsUnloading.contains(modelId) {
                await waitForModelUnload(modelId)
                if isShuttingDown { throw CancellationError() }
            }
            if modelSlots[modelId] != nil { return }
            try await ensureModelLoaded(modelId: modelId)
            return
        }

        guard let modelPath = ModelScanner.resolveLocalPath(modelID: modelId) else {
            throw InferenceError.invalidModelDirectory(
                "Model '\(modelId)' not found in local HuggingFace cache"
            )
        }

        guard let modelInfo = loopConfig.models.first(where: { $0.id == modelId }) else {
            throw InferenceError.invalidModelDirectory(
                "Model '\(modelId)' not in advertised model list"
            )
        }

        // Serialize loads so concurrent eviction decisions don't interleave
        while isLoadingAny {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                loadGateWaiters.append(cont)
            }
            // Honor cancellation (e.g. shutdown cancelled this preload task
            // while it was suspended at the gate).
            try Task.checkCancellation()
            if isShuttingDown { throw CancellationError() }
            while modelsUnloading.contains(modelId) {
                await waitForModelUnload(modelId)
                if isShuttingDown { throw CancellationError() }
            }
            if modelSlots[modelId] != nil { return }
        }
        isLoadingAny = true

        // Re-check slot cap after gate (another load may have consumed a slot)
        if modelSlots.count >= maxModelSlots {
            let modelsWithInflight = Set(requestToModel.values)
            let evictable = modelSlots.filter {
                !modelsWithInflight.contains($0.key) && !hasLocalReservation($0.key) && !modelsUnloading.contains($0.key)
            }
            if evictable.isEmpty {
                isLoadingAny = false
                releaseLoadGateWaiters()
                throw InferenceError.invalidModelDirectory(
                    "All \(maxModelSlots) model slot(s) are active; cannot load '\(modelId)'"
                )
            }
            if let lru = evictable.min(by: { $0.value.lastInferenceAt < $1.value.lastInferenceAt }) {
                await unloadModel(lru.key)
            }
        }

        modelsLoading.insert(modelId)
        do {
            try Task.checkCancellation()
            if isShuttingDown { throw CancellationError() }

            // Load gate: require room for the WEIGHTS plus headroom for ONE
            // request, not a full-concurrency multiple. Concurrency beyond one
            // request is sized dynamically at runtime by the live token budget +
            // GlobalKVCacheBudget (which strictly rejects any request whose KV
            // won't fit real free memory, so this looser gate cannot OOM — worst
            // case a box serves one request at a time). The old gate demanded
            // free ≥ weights × 2.86 (a `× 2.0` here on top of a `× 0.7` discount
            // in availableMemoryGb) and left every small/mid machine unable to
            // load a model it could actually serve. `availableMemoryGb` now
            // clamps to real OS-available memory and subtracts in-flight KV
            // reservations, so dropping the multiplier here is still OOM-safe.
            let requiredGb = ModelLoadAdmission.requiredToLoadGb(
                weightsGb: modelInfo.estimatedMemoryGb,
                headroomGb: Self.loadHeadroomGb)
            do {
                try await evictUntilAvailable(requiredGb: requiredGb)
            } catch let InferenceError.modelLoadFailed(message) {
                // Record for diagnostics so `doctor` shows the operator the exact
                // "Insufficient memory …" reason, then rethrow unchanged.
                recordModelLoadError(model: modelId, message: message)
                throw InferenceError.modelLoadFailed(message)
            }
            try Task.checkCancellation()
            if isShuttingDown { throw CancellationError() }

            logger.info("Loading model: \(modelId) from \(modelPath.path)")

            if let beforeModelLoad {
                await beforeModelLoad(modelId)
                try Task.checkCancellation()
                if isShuttingDown { throw CancellationError() }
            }
            let container = try await loadModelContainer(from: modelPath)
            try Task.checkCancellation()
            if isShuttingDown { throw CancellationError() }
            let scheduler = BatchScheduler(
                maxConcurrentRequests: Self.schedulerMaxConcurrent,
                pendingTimeout: Self.schedulerPendingTimeout,
                defaultMaxTokens: Self.schedulerDefaultMaxTokens,
                kvBudget: kvBudget
            )
            await scheduler.loadModel(container: container, modelId: modelId)
            if isShuttingDown || Task.isCancelled {
                await scheduler.unloadModel()
                throw CancellationError()
            }

            let tokenizer: TokenizerHandle = await container.perform { ctx in
                TokenizerHandle(ctx.tokenizer)
            }
            modelSlots[modelId] = ModelSlot(
                scheduler: scheduler,
                container: container,
                tokenizer: tokenizer,
                lastInferenceAt: .now
            )

            syncWarmModelState()
            await updateAggregateCapacity()
            logger.info("Model loaded: \(modelId) (\(modelSlots.count) model(s) in memory)")

            modelsLoading.remove(modelId)
            isLoadingAny = false
            for waiter in loadingWaiters.removeValue(forKey: modelId) ?? [] {
                waiter.resume()
            }
            releaseLoadGateWaiters()
        } catch {
            modelsLoading.remove(modelId)
            isLoadingAny = false
            for waiter in loadingWaiters.removeValue(forKey: modelId) ?? [] {
                waiter.resume(throwing: error)
            }
            releaseLoadGateWaiters()
            throw error
        }
    }

    private func releaseLoadGateWaiters() {
        let waiters = loadGateWaiters
        loadGateWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForModelUnload(_ modelId: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            unloadingWaiters[modelId, default: []].append(cont)
        }
    }

    private func unloadModel(_ modelId: String) async {
        guard let slot = modelSlots[modelId], !modelsUnloading.contains(modelId) else { return }
        modelsUnloading.insert(modelId)
        await slot.scheduler.unloadModel()
        modelSlots.removeValue(forKey: modelId)
        modelsUnloading.remove(modelId)
        let waiters = unloadingWaiters.removeValue(forKey: modelId) ?? []
        for waiter in waiters { waiter.resume() }
        syncWarmModelState()
        await updateAggregateCapacity()
        logger.info("Unloaded model: \(modelId) (\(modelSlots.count) model(s) remaining)")
    }

    private func syncWarmModelState() {
        let loaded = modelSlots.keys.filter { !modelsUnloading.contains($0) }.sorted()
        state.warmModels = loaded
        let activeSlots = modelSlots.filter { !modelsUnloading.contains($0.key) }
        let inflightModels = Set(requestToModel.values)
        let currentCandidates = activeSlots.filter { inflightModels.contains($0.key) }
        let candidates = currentCandidates.isEmpty ? activeSlots : currentCandidates
        if let mostRecent = candidates.max(by: { $0.value.lastInferenceAt < $1.value.lastInferenceAt }) {
            state.currentModel = mostRecent.key
            state.currentModelHash = loopConfig.modelHashes[mostRecent.key]
        } else {
            state.currentModel = nil
            state.currentModelHash = nil
        }
    }

    /// Physical memory (GB) available to LOAD a model. No 0.7 KV-safety discount
    /// here — weights are a known one-time allocation, and the 0.7 runtime
    /// safety is already enforced per request by GlobalKVCacheBudget. Applying it
    /// twice was the double-count that kept capable machines from ever loading a
    /// model they could serve.
    ///
    /// Two OOM-safety clamps make the looser gate sound:
    ///   1. The free figure is clamped to what the OS actually reports available
    ///      (`SystemMemory.availableBytes`), not just `total − MLX.active −
    ///      MLX.cache`, which over-reports whenever the OS/other processes hold
    ///      RAM.
    ///   2. KV already promised to in-flight requests
    ///      (`kvBudget.outstandingReservedBytes`) is subtracted, so a concurrent
    ///      load can't consume memory a mid-decode request is counting on.
    ///
    /// `doctor`'s model-fit check shares the SAME arithmetic via
    /// `ModelLoadAdmission`, so the operator-facing verdict can never drift from
    /// what this method enforces at load time.
    private func availableMemoryGb() async -> Double {
        let outstanding = await kvBudget.outstandingReservedBytes()
        return ModelLoadAdmission.freeForLoadGb(
            totalBytes: ProcessInfo.processInfo.physicalMemory,
            systemAvailableBytes: SystemMemory.availableBytes() ?? .max,
            gpuActiveBytes: UInt64(max(0, MLX.GPU.activeMemory)),
            gpuCacheBytes: UInt64(max(0, MLX.GPU.cacheMemory)),
            reserveBytes: Self.memoryReserveBytes(forGiB: loopConfig.config.provider.memoryReserveGB),
            outstandingReservationBytes: outstanding)
    }

    /// Headroom (GB) reserved above the weights at load time for ONE request.
    /// Concurrency beyond that is grown dynamically by the runtime token budget.
    static let loadHeadroomGb = ModelLoadAdmission.defaultLoadHeadroomGb

    private static func saturatingAdd(_ values: UInt64...) -> UInt64 {
        var total: UInt64 = 0
        for value in values {
            let (sum, overflow) = total.addingReportingOverflow(value)
            if overflow { return UInt64.max }
            total = sum
        }
        return total
    }

    /// Evict idle models (LRU order) until `requiredGb` is available or
    /// no more idle models remain. Re-checks in-flight state before each
    /// eviction since `await unloadModel` is a suspension point.
    /// Throws if the memory target cannot be met after exhausting evictable models.
    private func evictUntilAvailable(requiredGb: Double) async throws {
        while await availableMemoryGb() < requiredGb {
            let modelsWithInflight = Set(requestToModel.values)
            let candidate = modelSlots
                .filter { !modelsWithInflight.contains($0.key) && !hasLocalReservation($0.key) && !modelsUnloading.contains($0.key) }
                .min(by: { $0.value.lastInferenceAt < $1.value.lastInferenceAt })

            guard let (modelId, _) = candidate else {
                let available = String(format: "%.1f", await availableMemoryGb())
                let required = String(format: "%.1f", requiredGb)
                throw InferenceError.modelLoadFailed(
                    "Insufficient memory (\(available) GB free, need \(required) GB) and all loaded models are actively serving"
                )
            }

            logger.info("Evicting idle model \(modelId) to free memory")
            await unloadModel(modelId)
        }
    }

    /// Fast, non-mutating pre-accept admission check used by
    /// ``handleInferenceRequest``. Returns `true` only when loading `modelId`
    /// right now is *certain* to fail, so the coordinator can reroute instead
    /// of us accepting-then-failing (which it counts as a provider fault).
    ///
    /// It mirrors the terminal failure points in ``ensureModelLoaded`` /
    /// ``evictUntilAvailable`` WITHOUT loading anything and is deliberately
    /// conservative: anything that *could* succeed (including via eviction of
    /// an idle model) is admitted and left for the post-accept load path.
    private func fastAdmissionReject(modelId: String) async -> Bool {
        // Already resident — definitely serviceable.
        if modelSlots[modelId] != nil {
            return false
        }

        // Without advertised model info we cannot size the load here; let the
        // post-accept path surface the proper 404 rather than guessing.
        guard let modelInfo = loopConfig.models.first(where: { $0.id == modelId }) else {
            return false
        }
        let requiredGb = ModelLoadAdmission.requiredToLoadGb(
            weightsGb: modelInfo.estimatedMemoryGb,
            headroomGb: Self.loadHeadroomGb)

        // Sample live memory FIRST — this is the only suspension point in the
        // method (it awaits the KV-budget actor). Reading all the actor-local
        // slot/in-flight state AFTER the await means the decision below is made
        // atomically with respect to this actor: nothing can mutate slots
        // between the reads and the verdict, so there is no TOCTOU window.
        let available = await availableMemoryGb()

        // Re-check residency after the suspension: the model may have been
        // loaded by a concurrent request while we were awaiting memory.
        if modelSlots[modelId] != nil {
            return false
        }

        // An idle slot (loaded, no in-flight work, not already unloading) can be
        // evicted to make room, so its presence means we must NOT pre-reject.
        let modelsWithInflight = Set(requestToModel.values)
        let hasEvictable = modelSlots.contains {
            !modelsWithInflight.contains($0.key) && !hasLocalReservation($0.key) && !modelsUnloading.contains($0.key)
        }

        // Mirrors evictUntilAvailable's terminal failure: not enough free
        // memory and nothing idle to free.
        if available < requiredGb && !hasEvictable {
            return true
        }

        // Mirrors the slot-cap guard in ensureModelLoaded: all slots full and
        // none idle to evict.
        if modelSlots.count >= maxModelSlots && !hasEvictable {
            return true
        }

        return false
    }

    /// Map a model-load failure to an HTTP status code so the coordinator can
    /// react appropriately: transient capacity/memory pressure should reroute
    /// (503) and genuinely missing/unadvertised models are 404; anything else
    /// is treated as a real provider fault (500).
    static func loadErrorStatusCode(for error: any Error) -> UInt16 {
        guard let inferenceError = error as? InferenceError else {
            return 500
        }
        switch inferenceError {
        case .modelLoadFailed:
            // Out-of-memory / eviction failure from evictUntilAvailable —
            // transient capacity pressure, so let the coordinator reroute.
            return 503
        case .invalidModelDirectory(let message):
            let lowered = message.lowercased()
            if lowered.contains("slot") {
                // "All N model slot(s) are active; cannot load ..." — transient
                // capacity, not a fault.
                return 503
            }
            if lowered.contains("not found") || lowered.contains("advertised") {
                // Missing on disk or not in the advertised model list.
                return 404
            }
            return 500
        case .noModelLoaded, .generationFailed, .unsupportedRole:
            return 500
        }
    }

    private func loadModelContainer(from directory: URL) async throws -> MLXLMCommon.ModelContainer {
        try await LLMModelFactory.shared.loadContainer(
            from: directory,
            using: LocalTokenizerLoader()
        )
    }

    // MARK: - Cancellation

    private func handleCancellation(requestId: String) async {
        logger.info("Cancelling request: \(requestId)")

        // P1 #1 (CRITICAL): do NOT call `scheduler.cancel(requestId:)`
        // directly here. After the MLXLMServer adoption,
        // `MultiModelBatchSchedulerEngine.streamChatCompletion` mints
        // a fresh internal request id when it calls
        // `BatchScheduler.submit(requestId:)`, so the coordinator-side
        // `requestId` we hold here does NOT match the id the scheduler
        // is tracking. A direct `scheduler.cancel(<coordinator id>)`
        // would be a no-op against an unknown id and let generation run
        // until on-termination tearing happens organically.
        //
        // Instead, rely on Task cancellation propagation:
        //
        //   ProviderLoop.task.cancel()
        //     -> `for try await frame in frames` raises CancellationError
        //     -> the detached task exits, the `frames` AsyncThrowingStream
        //        is deallocated, its `onTermination` fires
        //     -> MLXOpenAIService.streamChatCompletionFrames's inner
        //        task is cancelled, its iteration on the engine stream
        //        exits, the engine stream is deallocated, its
        //        `onTermination` fires
        //     -> MultiModelBatchSchedulerEngine.streamChatCompletion's
        //        `onTermination` calls
        //        `scheduler.cancel(<internal id>)` with the correct id.
        //
        // The cancellation-registry token below remains so the explicit
        // `if token.isCancelled` check inside the streaming loop also
        // fires on the next iteration (defense in depth — both paths
        // reach the same teardown).
        await cancellationRegistry.cancel(requestId: requestId)

        if requestToModel.removeValue(forKey: requestId) != nil {
            powerAssertion.release()
        }

        syncWarmModelState()
        await updateAggregateCapacity()

        if let task = inflightTasks.removeValue(forKey: requestId) {
            task.cancel()
        }
    }

    private func cancelAllInflight() async {
        let requestIds = Array(inflightTasks.keys)
        for requestId in requestIds {
            await handleCancellation(requestId: requestId)
        }
        inflightTasks.removeAll()
        completedBeforeTaskRegistration.removeAll()
        if !requestToModel.isEmpty {
            powerAssertion.releaseAll()
        }
        requestToModel.removeAll()
        syncWarmModelState()
    }

    private func finishInflightRequest(requestId: String) async {
        let hadRegisteredTask = inflightTasks.removeValue(forKey: requestId) != nil
        let modelId = requestToModel.removeValue(forKey: requestId)
        if !hadRegisteredTask, modelId != nil {
            completedBeforeTaskRegistration.insert(requestId)
        }
        if let modelId {
            powerAssertion.release()
            modelSlots[modelId]?.lastInferenceAt = .now
            syncWarmModelState()
        }
        await updateAggregateCapacity()
    }

    private func waitForInflightDrain(timeout: Duration) async -> Bool {
        guard !inflightTasks.isEmpty || !requestToModel.isEmpty else { return true }
        logger.info("Waiting up to \(timeout.components.seconds)s for active inference to finish before shutdown")
        let started = ContinuousClock.now
        while !inflightTasks.isEmpty || !requestToModel.isEmpty {
            if Task.isCancelled { return false }
            if ContinuousClock.now - started >= timeout {
                return false
            }
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return false
            }
        }
        return true
    }

    private func updateAggregateCapacity() async {
        var allSlots: [BackendSlotCapacity] = []
        var totalActive = 0
        let slots = modelSlots.filter { !modelsUnloading.contains($0.key) }
        for (_, slot) in slots {
            let cap = await slot.scheduler.backendCapacity()
            allSlots.append(contentsOf: cap.slots)
            let schedCap = await slot.scheduler.capacity()
            totalActive += schedCap.activeRequests
        }

        let gbDivisor = 1024.0 * 1024.0 * 1024.0
        let totalMem = ProcessInfo.processInfo.physicalMemory
        state.backendCapacity = BackendCapacity(
            slots: allSlots,
            gpuMemoryActiveGb: Double(MLX.GPU.activeMemory) / gbDivisor,
            gpuMemoryPeakGb: Double(MLX.GPU.peakMemory) / gbDivisor,
            gpuMemoryCacheGb: Double(MLX.GPU.cacheMemory) / gbDivisor,
            totalMemoryGb: Double(totalMem) / gbDivisor
        )
        state.inferenceActive = totalActive > 0
    }

    // MARK: - Attestation Challenge

    private func handleAttestationChallenge(
        nonce: String,
        timestamp: String,
        send: SendHandle
    ) async {
        logger.info("Handling attestation challenge (timestamp: \(timestamp))")

        guard let builder = attestationBuilder else {
            logger.warning("No Secure Enclave identity -- cannot respond to attestation challenge")
            return
        }

        do {
            let activeModelHash = state.currentModel.flatMap { modelId in
                loopConfig.modelHashes[modelId]
            }

            let response = try builder.buildChallengeResponse(
                nonce: nonce,
                timestamp: timestamp,
                providerPublicKey: keyPair.publicKeyBase64,
                binaryHash: binaryHash,
                activeModelHash: activeModelHash,
                runtimeHashes: augmentRuntimeHashesWithMetallib(loopConfig.runtimeHashes),
                modelHashes: loopConfig.modelHashes
            )

            send.send(.attestationResponse(AttestationResponsePayload(
                nonce: response.nonce,
                signature: response.signature,
                statusSignature: response.statusSignature,
                publicKey: response.publicKey,
                hypervisorActive: response.hypervisorActive,
                rdmaDisabled: response.rdmaDisabled,
                sipEnabled: response.sipEnabled,
                secureBootEnabled: response.secureBootEnabled,
                binaryHash: response.binaryHash,
                activeModelHash: response.activeModelHash,
                pythonHash: response.pythonHash,
                runtimeHash: response.runtimeHash,
                templateHashes: response.templateHashes,
                modelHashes: response.modelHashes
            )))

            logger.info("Attestation challenge response sent")
        } catch {
            logger.error("Failed to sign attestation challenge: \(error)")
        }
    }

    // MARK: - Helpers
    //
    // SSE parsing, error-status mapping, and inbound request decoding
    // live in companion extension files for navigability:
    //   - ProviderLoop+SSEParser.swift     (StreamChunkExtract, parseStreamChunk, encodeToolCallsForHash)
    //   - ProviderLoop+ErrorMapping.swift  (mapInferenceErrorToStatus)
    //   - ProviderLoop+InboundDecode.swift (decodeOpenAIRequest; see InboundChatNormalization)
}

// MARK: - Logger wrapper

/// Unified logger that uses os.Logger on macOS. Internal access so
/// the `+SSEParser.swift` extension file can re-use it for its
/// file-scope logger (parseStreamChunk is a `static` method and
/// can't reach the per-instance logger on the actor).
struct ProviderLogger: Sendable {
    #if canImport(os)
    private let osLogger: os.Logger
    #endif
    private let category: String

    init(subsystem: String, category: String) {
        self.category = category
        #if canImport(os)
        self.osLogger = os.Logger(subsystem: subsystem, category: category)
        #endif
    }

    func info(_ message: String) {
        #if canImport(os)
        osLogger.info("\(message, privacy: .public)")
        #else
        print("[\(category)] INFO: \(message)")
        #endif
    }

    func warning(_ message: String) {
        #if canImport(os)
        osLogger.warning("\(message, privacy: .public)")
        #else
        print("[\(category)] WARN: \(message)")
        #endif
    }

    func error(_ message: String) {
        #if canImport(os)
        osLogger.error("\(message, privacy: .public)")
        #else
        print("[\(category)] ERROR: \(message)")
        #endif
    }
}

// MARK: - Import bridge

import MLX
import MLXLLM
import MLXLMCommon

// MARK: - Unified local endpoint

/// Serves a local OpenAI-compatible HTTP endpoint alongside coordinator serving,
/// backed by the SAME loaded models (`modelSlots`) so weights load once and
/// local + coordinator requests feed the same continuous-batching engine and the
/// same `GlobalKVCacheBudget` (so reported capacity reflects local load too).
///
/// Kept as a same-file extension so it can reach `ProviderLoop`'s private model
/// registry / load path without loosening their access for the whole module.
extension ProviderLoop {
    /// Start the local endpoint (idempotent). Runs the shared HTTP app in a
    /// child task; its registry closures reach back into this actor.
    func startLocalEndpoint(_ cfg: LocalInferenceHTTPConfig) {
        guard localServerTask == nil else { return }
        let app = makeLocalInferenceApplication(
            config: cfg,
            defaultMaxTokens: Self.schedulerDefaultMaxTokens,
            acquire: { [weak self] modelId in
                guard let self else { throw MultiModelBatchSchedulerEngineError.modelNotLoaded(modelId) }
                return try await self.acquireModelForLocal(modelId)
            },
            tokenizerProvider: { [weak self] modelId in
                guard let self else { throw MultiModelBatchSchedulerEngineError.noModelLoadedForTokenization }
                return try await self.resolveTokenizerForLocal(modelId)
            },
            availableModels: { [weak self] in
                guard let self else { return [] }
                return await self.advertisedLocalModelIds()
            },
            // Fires only once OUR server has actually bound the socket — the
            // authoritative bind signal. We publish discovery here (never from a
            // best-effort HTTP probe that a foreign process on the same port
            // could answer). If the bind fails, runService throws below and this
            // never runs, so no stale/foreign discovery record is written.
            onServerRunning: { [weak self] _ in
                await self?.onLocalEndpointBound(cfg)
            }
        )
        let log = logger
        localServerTask = Task {
            do {
                try await app.runService(gracefulShutdownSignals: [])
            } catch is CancellationError {
                // expected on shutdown
            } catch {
                // A bind failure (e.g. port already in use) lands here. We do NOT
                // kill the provider — coordinator serving must stay up — but make
                // the local-endpoint failure loud and operator-actionable.
                log.error("Local OpenAI endpoint did NOT bind on \(cfg.host):\(cfg.port) (port already in use?): \(error.localizedDescription). Coordinator serving is unaffected; restart with a free --port to enable the local endpoint.")
            }
        }
    }

    /// Invoked by Hummingbird once the local endpoint socket is bound and
    /// listening. Publishes the discovery record so `darkbloom local` /
    /// local-first clients find the unified endpoint — only now that the bind is
    /// CONFIRMED to be ours.
    private func onLocalEndpointBound(_ cfg: LocalInferenceHTTPConfig) {
        logger.info("Local OpenAI endpoint listening on \(cfg.host):\(cfg.port) (unified mode)")
        try? LocalEndpoint.writeInfo(LocalEndpoint.Info(
            host: cfg.host,
            port: cfg.port,
            apiKey: cfg.authToken ?? "",
            version: ProviderCore.version,
            pid: ProcessInfo.processInfo.processIdentifier,
            updatedAt: ISO8601DateFormatter().string(from: Date())
        ))
    }

    /// Stop the local endpoint server, if running, and remove its discovery record.
    func stopLocalEndpoint() {
        guard localServerTask != nil else { return }
        localServerTask?.cancel()
        localServerTask = nil
        LocalEndpoint.removeInfo()
    }

    /// Acquire a resident model for a LOCAL request: ensure it's loaded, then
    /// hold a local reservation (released by the engine when the stream ends) so
    /// the idle monitor and load-gate eviction can't pull it mid-stream. Loading
    /// goes through the same `ensureModelLoaded` gate as coordinator requests, so
    /// the shared `GlobalKVCacheBudget` and memory admission apply uniformly.
    func acquireModelForLocal(_ modelId: String) async throws -> MultiModelBatchSchedulerEngine.AcquiredModel {
        do {
            try await ensureModelLoaded(modelId: modelId)
        } catch let err as InferenceError {
            // Map load failures to the engine's typed errors (404 / 503).
            switch err {
            case .invalidModelDirectory, .noModelLoaded:
                throw MultiModelBatchSchedulerEngineError.modelNotLoaded(modelId)
            default:
                throw MultiModelBatchSchedulerEngineError.queueFull("local capacity unavailable for \(modelId)")
            }
        }
        guard let slot = modelSlots[modelId] else {
            throw MultiModelBatchSchedulerEngineError.modelNotLoaded(modelId)
        }
        localReservations.reserve(modelId)
        modelSlots[modelId]?.lastInferenceAt = .now
        let release: @Sendable (String) async -> Void = { [weak self] mid in
            await self?.releaseLocalReservation(mid)
        }
        return MultiModelBatchSchedulerEngine.AcquiredModel(
            scheduler: slot.scheduler,
            tokenizer: slot.tokenizer,
            releaseToken: OneShotRelease(release: release, modelId: modelId),
            modelType: loopConfig.models.first(where: { $0.id == modelId })?.modelType
        )
    }

    /// Drop one local in-flight reservation for a model.
    func releaseLocalReservation(_ modelId: String) {
        localReservations.release(modelId)
        modelSlots[modelId]?.lastInferenceAt = .now
    }

    /// Whether a model currently has a local request in flight. Used by the idle
    /// monitor and eviction so they never unload a model a local stream is using.
    func hasLocalReservation(_ modelId: String) -> Bool {
        localReservations.isReserved(modelId)
    }

    /// Resolve a tokenizer for the local token-utility endpoints. Read-only, so
    /// (unlike `acquireModelForLocal`) it takes no reservation.
    func resolveTokenizerForLocal(_ modelId: String?) async throws -> TokenizerHandle {
        if let modelId {
            guard let slot = modelSlots[modelId] else {
                throw MultiModelBatchSchedulerEngineError.modelNotLoaded(modelId)
            }
            return slot.tokenizer
        }
        if let firstKey = modelSlots.keys.sorted().first, let slot = modelSlots[firstKey] {
            return slot.tokenizer
        }
        throw MultiModelBatchSchedulerEngineError.noModelLoadedForTokenization
    }

    /// The advertised `/v1/models` catalog for the local endpoint — everything
    /// this provider is configured to serve, not just the resident subset.
    func advertisedLocalModelIds() -> [String] {
        loopConfig.models.map { $0.id }.sorted()
    }
}
