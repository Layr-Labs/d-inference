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
    /// When true the registration message includes `rdma_enabled: true`, making
    /// this provider visible in GET /v1/cluster/rdma-peers for peer auto-discovery.
    public let rdmaEnabled: Bool

    public init(
        coordinatorURL: String,
        hardware: HardwareInfo,
        models: [ModelInfo],
        config: ProviderConfig,
        authToken: String? = nil,
        runtimeHashes: RuntimeHashes? = nil,
        modelHashes: [String: String] = [:],
        rdmaEnabled: Bool = false
    ) {
        self.coordinatorURL = coordinatorURL
        self.hardware = hardware
        self.models = models
        self.config = config
        self.authToken = authToken
        self.runtimeHashes = runtimeHashes
        self.modelHashes = modelHashes
        self.rdmaEnabled = rdmaEnabled
    }
}

// MARK: - ProviderLoop

public actor ProviderLoop {
    private let loopConfig: ProviderLoopConfig
    private let keyPair: NodeKeyPair
    private let signer: (any AttestationSigner)?
    private let attestationBuilder: AttestationBuilder?
    private let scheduler: BatchScheduler
    private let stats: AtomicProviderStats
    private let state: ProviderState
    private let cancellationRegistry: InferenceCancellationRegistry

    /// Optional cluster discovery instance. When non-nil, `handleInferenceRequest`
    /// checks `clusterDiscovery.currentEngine()` (TP) or `currentPPEngine()` (PP)
    /// before falling back to the local `BatchScheduler`.
    public private(set) var clusterDiscovery: ClusterDiscovery?

    /// Tracks in-flight inference tasks by request ID so they can be cancelled.
    private var inflightTasks: [String: Task<Void, Never>] = [:]

    /// Cached security posture from startup verification.
    private var securityPosture: SecurityPosture?

    /// Cached binary hash for attestation responses.
    private var binaryHash: String?

    /// Timestamp of the last inference-related activity (request submitted
    /// or finished). The idle monitor compares this to `now` and unloads
    /// the model if no work has happened in `idleTimeoutMins`.
    private var lastInferenceAt: ContinuousClock.Instant = .now

    /// Background task that periodically checks idle state and unloads
    /// the model when the timeout has elapsed. nil when disabled
    /// (`idleTimeoutMins == 0`) or before `run()` starts it.
    private var idleMonitorTask: Task<Void, Never>?

    private let logger = ProviderLogger(subsystem: "dev.darkbloom.provider", category: "loop")

    // MARK: - Initialization

    public init(config: ProviderLoopConfig) throws {
        self.loopConfig = config
        NodeKeyPair.purgeLegacyFiles()
        self.keyPair = NodeKeyPair.generate()
        self.signer = Self.createAttestationSigner()
        self.attestationBuilder = signer.map { AttestationBuilder(identity: $0) }
        self.stats = AtomicProviderStats()
        self.state = ProviderState()
        self.cancellationRegistry = InferenceCancellationRegistry()
        self.scheduler = BatchScheduler(
            maxConcurrentRequests: 4,
            pendingTimeout: .seconds(120),
            defaultMaxTokens: 4096
        )
    }

    /// Inject a `ClusterDiscovery` instance before calling `run()`.
    /// Must be called from within the actor's isolation domain (i.e. using `await`).
    public func setClusterDiscovery(_ discovery: ClusterDiscovery?) {
        self.clusterDiscovery = discovery
    }

    /// Try persistent keychain-backed SE key first; fall back to ephemeral CryptoKit key.
    private static func createAttestationSigner() -> (any AttestationSigner)? {
        let log = ProviderLogger(subsystem: "dev.darkbloom.provider", category: "loop")

        if PersistentEnclaveKey.isAvailable {
            do {
                let key = try PersistentEnclaveKey.loadOrCreate()
                log.info("Using persistent keychain-backed Secure Enclave key for attestation")
                return key
            } catch {
                log.warning("Persistent SE key unavailable (\(error)), falling back to ephemeral")
            }
        }

        do {
            return try SecureEnclaveIdentity.createEphemeral()
        } catch {
            log.warning("Ephemeral SE identity also unavailable: \(error)")
            return nil
        }
    }

    /// Background task that syncs `ClusterDiscovery.clusterRole` into
    /// `ProviderState.clusterRole` so heartbeats carry the correct value.
    private var clusterRoleSyncTask: Task<Void, Never>?

    // MARK: - Main Run Loop

    public func run() async throws {
        logger.info("darkbloom \(ProviderCore.version) starting")
        logger.info("Hardware: \(loopConfig.hardware.chipName), \(loopConfig.hardware.memoryGb) GB RAM, \(loopConfig.hardware.gpuCores) GPU cores")
        logger.info("Models: \(loopConfig.models.count) advertised")
        logger.info("Coordinator: \(loopConfig.coordinatorURL)")

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
            rdmaEnabled: loopConfig.rdmaEnabled
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

        // Sync cluster role from ClusterDiscovery into ProviderState so
        // heartbeats include the correct cluster_role field. Poll every 5 s —
        // fast enough to be reflected in the next heartbeat (default 30 s).
        startClusterRoleSync()

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
                }
            }
        } onCancel: {
            Task { await coordinator.shutdown() }
        }

        logger.info("Event stream ended, shutting down")
        idleMonitorTask?.cancel()
        idleMonitorTask = nil
        clusterRoleSyncTask?.cancel()
        clusterRoleSyncTask = nil
        await coordinator.shutdown()
        await cancelAllInflight()
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
                binaryHash: binaryHash,
                rdmaEnabled: loopConfig.rdmaEnabled
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

        // 2. Parse the chat completion request
        let chatRequest: ChatCompletionRequest
        do {
            chatRequest = try JSONDecoder().decode(ChatCompletionRequest.self, from: decryptedData)
        } catch {
            logger.error("[\(requestId)] Failed to parse chat request: \(error)")
            send.send(.inferenceError(requestId: requestId, error: "invalid request body: \(error.localizedDescription)", statusCode: 400))
            return
        }

        // 3. Send inference_accepted
        send.send(.inferenceAccepted(requestId: requestId))

        // 4. Ensure model is loaded
        let modelId = chatRequest.model
        do {
            try await ensureModelLoaded(modelId: modelId)
        } catch {
            logger.error("[\(requestId)] Failed to load model '\(modelId)': \(error)")
            send.send(.inferenceError(requestId: requestId, error: "model load failed: \(error.localizedDescription)", statusCode: 500))
            return
        }

        // 5. Register cancellation token
        let token = await cancellationRegistry.register(requestId: requestId)

        // 6. Capture values for the spawned task
        let responsePublicKeyData: Data = senderKey
        let kp = self.keyPair
        let sched = self.scheduler
        let providerStats = self.stats
        let providerState = self.state
        let registry = self.cancellationRegistry
        let signingIdentity = self.signer
        let log = self.logger

        // 7. Check for an active cluster engine (rank 0 only).
        //    Rank 1 never reaches this point for cluster-bound requests because
        //    the coordinator skips it (ClusterRole=1). If somehow a rank-1 provider
        //    receives a direct request (bypassing the coordinator), it falls through
        //    to the local BatchScheduler — correct behaviour, never dispatch to serve().
        let clusterEngine: ClusterEngine?
        if let discovery = clusterDiscovery {
            if let tpEngine = await discovery.currentEngine() {
                clusterEngine = .tp(tpEngine)
            } else if let ppEngine = await discovery.currentPPEngine() {
                clusterEngine = .pp(ppEngine)
            } else {
                clusterEngine = nil
            }
        } else {
            clusterEngine = nil
        }

        // 8. Tokenizer for the cluster path (decode raw token IDs → text).
        //    Only fetched when a cluster engine is available; nil means fall
        //    back to the local BatchScheduler path regardless.
        let clusterTokenizer: (any MLXLMCommon.Tokenizer)? = clusterEngine != nil
            ? await sched.currentTokenizer()
            : nil

        // 9. Resolve the request's max-token budget (mirrors the local path default).
        let requestMaxTokens = chatRequest.max_tokens ?? 4096

        // 10. Spawn inference task
        let task = Task.detached {
            defer {
                Task { await registry.finish(requestId: requestId) }
            }

            providerState.inferenceActive = true

            var usageAccumulator = UsageAccumulator()
            var fullResponseText = ""
            let formatter = ChatSSEFormatter()
            let responseId = "chatcmpl-\(UUID().uuidString.prefix(12).lowercased())"
            let created = Int(Date().timeIntervalSince1970)

            let emitSSE: @Sendable (String) -> Void = { sseData in
                var encryptedPayload: EncryptedPayload?
                do {
                    encryptedPayload = try kp.encryptPayload(
                        recipientPublicKey: responsePublicKeyData,
                        plaintext: Data(sseData.utf8)
                    )
                } catch {
                    log.warning("[\(requestId)] Chunk encryption failed: \(error)")
                }

                send.send(.inferenceChunk(
                    requestId: requestId,
                    data: encryptedPayload != nil ? "" : sseData,
                    encryptedData: encryptedPayload
                ))
            }

            if let roleChunk = try? formatter.roleChunk(
                id: responseId,
                model: chatRequest.model,
                created: created
            ) {
                emitSSE(roleChunk.formatted)
            }

            // ----------------------------------------------------------------
            // Cluster path: dispatch through TensorParallelEngine or
            // EncryptedPipelineEngine when a cluster session is active.
            // ----------------------------------------------------------------
            if let engine = clusterEngine, let tokenizer = clusterTokenizer {
                log.info("[\(requestId)] Dispatching via cluster engine (\(engine.label))")

                // Tokenize the chat prompt into token IDs using the model's
                // chat template. This mirrors what BatchScheduler.submit() does.
                let promptTokens: [Int]
                do {
                    let messages: [[String: any Sendable]] = chatRequest.messages.map { msg in
                        ["role": msg.role, "content": msg.content]
                    }
                    promptTokens = try tokenizer.applyChatTemplate(
                        messages: messages, tools: nil, additionalContext: nil)
                } catch {
                    log.error("[\(requestId)] Cluster path: chat prompt tokenization failed: \(error)")
                    send.send(.inferenceError(
                        requestId: requestId,
                        error: "tokenization failed: \(error.localizedDescription)",
                        statusCode: 500))
                    return
                }

                usageAccumulator.setPromptTokens(promptTokens.count)

                // Build EOS token set from the tokenizer.
                var eosTokenIDs = Set<Int>()
                if let eosToken = tokenizer.eosToken,
                   let eosId = tokenizer.convertTokenToId(eosToken) {
                    eosTokenIDs.insert(eosId)
                }

                // Run the generate loop with a per-request timeout budget.
                // If the cluster stream ends before EOS/maxTokens without
                // Task cancellation, treat it as a link failure → 503.
                //
                // Swift 6 concurrency note: we cannot mutate `fullResponseText`
                // inside `group.addTask` because the outer closure also captures it.
                // Instead, the token-consumer task returns the accumulated text +
                // token count as its result, and we write to `fullResponseText`
                // after the task group completes.
                let requestTimeout: Duration = .seconds(120)

                let tokenStream = await engine.generate(
                    promptTokens: promptTokens,
                    maxTokens: requestMaxTokens,
                    eosTokenIDs: eosTokenIDs)

                // Wrap the stream in a timeout task group so we don't hang
                // indefinitely if the peer dies mid-decode.
                let timeoutResult = await withTaskGroup(of: ClusterStreamResult.self) { group in
                    // Task A: consume the token stream.
                    // All SSE emission happens inside this task via `emitSSE`;
                    // text is accumulated locally and returned with the result
                    // so it never crosses the task boundary as a mutable var.
                    group.addTask {
                        var detokenizer = NaiveStreamingDetokenizer(tokenizer: tokenizer)
                        var localText = ""
                        var count = 0
                        for await tokenID in tokenStream {
                            if token.isCancelled { break }
                            detokenizer.append(token: tokenID)
                            if let piece = detokenizer.next(), !piece.isEmpty {
                                localText += piece
                                if let chunk = try? formatter.contentChunk(
                                    id: responseId,
                                    model: chatRequest.model,
                                    created: created,
                                    text: piece
                                ) {
                                    emitSSE(chunk.formatted)
                                }
                            }
                            count += 1
                        }
                        // Flush any remaining text from the detokenizer.
                        if let tail = detokenizer.next(), !tail.isEmpty {
                            localText += tail
                            if let chunk = try? formatter.contentChunk(
                                id: responseId,
                                model: chatRequest.model,
                                created: created,
                                text: tail
                            ) {
                                emitSSE(chunk.formatted)
                            }
                        }
                        return .completed(tokenCount: count, text: localText)
                    }

                    // Task B: timeout watchdog.
                    group.addTask {
                        try? await Task.sleep(for: requestTimeout)
                        return .timedOut
                    }

                    // First result wins.
                    let first = await group.next() ?? .completed(tokenCount: 0, text: "")
                    group.cancelAll()
                    return first
                }

                var tokenCount = 0
                switch timeoutResult {
                case .completed(let count, let text):
                    tokenCount = count
                    fullResponseText = text
                case .timedOut:
                    log.warning("[\(requestId)] Cluster engine timed out after \(requestTimeout) — returning 503")
                    send.send(.inferenceError(
                        requestId: requestId,
                        error: "cluster inference timed out",
                        statusCode: 503))
                    return
                }

                if token.isCancelled {
                    log.info("[\(requestId)] Cluster path: cancelled during generation")
                    send.send(.inferenceError(
                        requestId: requestId,
                        error: "request cancelled",
                        statusCode: 499))
                    return
                }

                // Detect premature stream end: stream finished but we got 0
                // tokens and the prompt was non-empty — link failure.
                if tokenCount == 0 && !promptTokens.isEmpty {
                    log.warning("[\(requestId)] Cluster engine stream ended prematurely (0 tokens) — returning 503")
                    send.send(.inferenceError(
                        requestId: requestId,
                        error: "cluster peer disconnected mid-generation",
                        statusCode: 503))
                    return
                }

                usageAccumulator.setCompletionTokens(tokenCount)
                let usage = usageAccumulator.snapshot

                if let finishChunk = try? formatter.finishChunk(
                    id: responseId,
                    model: chatRequest.model,
                    created: created,
                    reason: .stop,
                    usage: usage
                ) {
                    emitSSE(finishChunk.formatted)
                    emitSSE(SSEChunk.done.formatted)
                }

                providerStats.incrementRequestsServed()
                providerStats.addTokensGenerated(UInt64(usage.completionTokens))
                providerState.inferenceActive = false

                let attestation = computeResponseAttestation(
                    identity: signingIdentity,
                    requestId: requestId,
                    completionTokens: UInt64(max(usage.completionTokens, 0)),
                    responseBody: fullResponseText
                )
                send.send(.inferenceComplete(
                    requestId: requestId,
                    usage: usage.protocolUsageInfo,
                    seSignature: attestation.signature,
                    responseHash: attestation.hash
                ))

                log.info("[\(requestId)] Cluster complete: \(usage.promptTokens) prompt + \(usage.completionTokens) completion tokens")
                return
            }

            // ----------------------------------------------------------------
            // Local path: submit to the BatchScheduler (existing behaviour).
            // ----------------------------------------------------------------
            log.info("[\(requestId)] Dispatching via local BatchScheduler")

            // Submit to the BatchScheduler
            let generationStream = await sched.submit(
                request: chatRequest,
                requestId: requestId
            )

            for await event in generationStream {
                // Check cancellation
                if token.isCancelled {
                    log.info("[\(requestId)] Cancelled during generation")
                    send.send(.inferenceError(requestId: requestId, error: "request cancelled", statusCode: 499))
                    return
                }

                switch event {
                case .chunk(let text):
                    fullResponseText += text
                    usageAccumulator.recordCompletionChunk()

                    if let contentChunk = try? formatter.contentChunk(
                        id: responseId,
                        model: chatRequest.model,
                        created: created,
                        text: text
                    ) {
                        emitSSE(contentChunk.formatted)
                    }

                case .info(let promptTokens, let completionTokens, _):
                    usageAccumulator.setPromptTokens(promptTokens)
                    usageAccumulator.setCompletionTokens(completionTokens)

                case .error(let errorMessage):
                    log.error("[\(requestId)] Generation error: \(errorMessage)")
                    send.send(.inferenceError(requestId: requestId, error: errorMessage, statusCode: 500))
                    return
                }
            }

            // Generation complete
            let usage = usageAccumulator.snapshot
            if let finishChunk = try? formatter.finishChunk(
                id: responseId,
                model: chatRequest.model,
                created: created,
                reason: .stop,
                usage: usage
            ) {
                emitSSE(finishChunk.formatted)
                emitSSE(SSEChunk.done.formatted)
            }

            // Update stats
            providerStats.incrementRequestsServed()
            providerStats.addTokensGenerated(UInt64(usage.completionTokens))

            // Update state
            let cap = await sched.backendCapacity()
            providerState.backendCapacity = cap
            if await sched.capacity().activeRequests == 0 {
                providerState.inferenceActive = false
            }

            // Send completion
            let attestation = computeResponseAttestation(
                identity: signingIdentity,
                requestId: requestId,
                completionTokens: UInt64(max(usage.completionTokens, 0)),
                responseBody: fullResponseText
            )
            send.send(.inferenceComplete(
                requestId: requestId,
                usage: usage.protocolUsageInfo,
                seSignature: attestation.signature,
                responseHash: attestation.hash
            ))

            log.info("[\(requestId)] Complete: \(usage.promptTokens) prompt + \(usage.completionTokens) completion tokens")
        }

        inflightTasks[requestId] = task
        lastInferenceAt = .now
    }

    // MARK: - Cluster engine dispatch helpers

    /// Tagged union for the two cluster engine types so the dispatch closure
    /// can call `.generate()` without knowing which protocol is in use.
    private enum ClusterEngine {
        case tp(TensorParallelEngine)
        case pp(EncryptedPipelineEngine)

        var label: String {
            switch self {
            case .tp: return "TP"
            case .pp: return "PP"
            }
        }

        /// Generate a stream of token IDs using the appropriate engine.
        func generate(
            promptTokens: [Int],
            maxTokens: Int,
            eosTokenIDs: Set<Int>
        ) async -> AsyncStream<Int> {
            switch self {
            case .tp(let engine):
                return await engine.generate(
                    promptTokens: promptTokens,
                    maxTokens: maxTokens,
                    eosTokenIDs: eosTokenIDs)
            case .pp(let engine):
                return await engine.generate(
                    promptTokens: promptTokens,
                    maxTokens: maxTokens,
                    eosTokenIDs: eosTokenIDs)
            }
        }
    }

    /// Result type for the cluster stream timeout task group.
    /// `completed` carries the accumulated response text and token count so
    /// the outer closure doesn't need to mutate a captured `var` from inside
    /// the task group (which would be a Swift 6 data-race violation).
    private enum ClusterStreamResult {
        case completed(tokenCount: Int, text: String)
        case timedOut
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
        if state.currentModel == modelId {
            logger.info("Preload for \(modelId): already loaded, replying succeeded")
            send.send(.loadModelStatus(
                modelId: modelId,
                status: .succeeded,
                error: nil
            ))
            return
        }

        send.send(.loadModelStatus(
            modelId: modelId,
            status: .started,
            error: nil
        ))

        let me = self
        Task {
            do {
                try await me.ensureModelLoaded(modelId: modelId)
                send.send(.loadModelStatus(
                    modelId: modelId,
                    status: .succeeded,
                    error: nil
                ))
            } catch {
                let message = error.localizedDescription
                await me.logPreloadFailure(modelId: modelId, error: message)
                send.send(.loadModelStatus(
                    modelId: modelId,
                    status: .failed,
                    error: message
                ))
            }
        }
    }

    private func logPreloadFailure(modelId: String, error: String) {
        logger.error("Preload for \(modelId) failed: \(error)")
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

    /// Single tick: unload the model if it's been idle longer than `timeout`.
    /// Runs on the actor so reads of `inflightTasks` and `state.currentModel`
    /// are coherent with request submission.
    private func tickIdleMonitor(timeout: Duration) async {
        guard let modelId = state.currentModel else { return }
        let elapsed = ContinuousClock.now - lastInferenceAt
        guard IdleTimeoutPolicy.shouldUnload(
            elapsed: elapsed,
            timeout: timeout,
            hasInflight: !inflightTasks.isEmpty,
            hasLoadedModel: true
        ) else { return }

        logger.info("Idle timeout exceeded (\(formatDuration(elapsed)) since last activity); unloading \(modelId)")
        await scheduler.unloadModel()
        state.currentModel = nil
        state.warmModels = []
        state.currentModelHash = nil
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

    // MARK: - Cluster role sync

    /// Periodically reads `ClusterDiscovery.clusterRole` and copies it into
    /// `ProviderState.clusterRole` so the heartbeat loop picks it up. Runs
    /// every 5 seconds (much faster than the 30-second heartbeat interval).
    private func startClusterRoleSync() {
        clusterRoleSyncTask?.cancel()
        guard clusterDiscovery != nil else { return }
        let me = self
        clusterRoleSyncTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { break }
                await me.syncClusterRole()
            }
        }
    }

    private func syncClusterRole() async {
        guard let discovery = clusterDiscovery else { return }
        let role = await discovery.clusterRole
        state.clusterRole = role
    }

    // MARK: - Model Loading

    private func ensureModelLoaded(modelId: String) async throws {
        // Check if already loaded
        if state.currentModel == modelId {
            return
        }

        // Resolve local path
        guard let modelPath = ModelScanner.resolveLocalPath(modelID: modelId) else {
            throw InferenceError.invalidModelDirectory(
                "Model '\(modelId)' not found in local HuggingFace cache"
            )
        }

        logger.info("Loading model: \(modelId) from \(modelPath.path)")

        let container = try await loadModelContainer(from: modelPath)
        await scheduler.loadModel(container: container, modelId: modelId)

        // Update shared state
        state.currentModel = modelId
        state.warmModels = [modelId]
        state.currentModelHash = loopConfig.modelHashes[modelId]

        // Hand the model directory to ClusterDiscovery so it can construct the
        // TP / PP engine once jaccl bootstrap completes. Without this call the
        // cluster path is unreachable: tryBuildRank{0,1}Engine bails on the
        // missing `modelDirectory` guard, both `currentEngine()` and
        // `currentPPEngine()` stay nil, and every inference request falls
        // through to the local BatchScheduler — silently making the whole
        // 4-PR cluster stack dead code in production.
        if let discovery = clusterDiscovery {
            await discovery.setModelDirectory(modelPath)
            logger.info("ClusterDiscovery model directory set: \(modelPath.path)")
        }

        logger.info("Model loaded: \(modelId)")
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

        // Cancel in the registry (triggers the token)
        await cancellationRegistry.cancel(requestId: requestId)

        // Cancel in the scheduler
        await scheduler.cancel(requestId: requestId)

        // Cancel the inflight task
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
    }

    private func removeInflightTask(requestId: String) {
        inflightTasks.removeValue(forKey: requestId)
        lastInferenceAt = .now
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

}

// MARK: - Logger wrapper

/// Unified logger that uses os.Logger on macOS.
private struct ProviderLogger: Sendable {
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
