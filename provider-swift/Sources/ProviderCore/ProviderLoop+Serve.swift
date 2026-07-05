/// ProviderLoop -- coordinator-serving run loop + registration setup.
///
/// The main `run()` event loop (connect, register, dispatch coordinator
/// events, graceful drain on shutdown) plus the security-hardening,
/// runtime-hash, and registration-attestation helpers it calls at startup.

import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXLMServer
import MLXVLM
#if canImport(os)
import os
#endif

extension ProviderLoop {
    // MARK: - Main Run Loop

    public func run() async throws {
        // FIRST, before any engine/model code can latch the library's
        // `CompiledDecode.isEnabled` static: force the legacy engine's
        // compiled decode OFF unless the operator opted in via config
        // (`legacy_compiled_decode = true`) or set the env var explicitly
        // (which always wins). Keeps release behavior identical to prod
        // v0.6.30 — see `LegacyCompiledDecodeGate`.
        if LegacyCompiledDecodeGate.apply(
            configEnabled: loopConfig.config.backend.legacyCompiledDecode)
        {
            logger.info("Legacy compiled decode disabled (legacy_compiled_decode=false, env unset)")
        }

        logger.info("darkbloom \(ProviderCore.version) starting")
        logger.info("Hardware: \(loopConfig.hardware.chipName), \(loopConfig.hardware.memoryGb) GB RAM, \(loopConfig.hardware.gpuCores) GPU cores")
        logger.info("Models: \(loopConfig.models.count) advertised")
        logger.info("Coordinator: \(loopConfig.coordinatorURL)")

        // Keep the network stack alive during sleep for APN/MDM push delivery.
        networkAssertion.acquire()
        defer { networkAssertion.release() }

        // Suppress App Nap for the lifetime of the serve loop. macOS throttles
        // "napping" background processes — Task.sleep-driven timers (heartbeat,
        // ping/pong) stop firing on schedule, the coordinator stops receiving
        // heartbeats and evicts us within 90s, and our own throttled ping takes
        // minutes to notice the dead socket: the connect→evict→reconnect churn.
        // .userInitiated suppresses App Nap; .idleSystemSleepDisabled keeps an
        // idle box awake while serving, on battery too (caffeinate -s is AC-only).
        let napAssertion = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled,
                      .suddenTerminationDisabled, .automaticTerminationDisabled],
            reason: "Darkbloom provider serving inference / keeping the coordinator link alive")
        defer { ProcessInfo.processInfo.endActivity(napAssertion) }

        // Crash recovery is owned by the WatchdogAgent (separate launchd job,
        // #315) — installed from the serve path, so it reaches auto-updated
        // installs too. KeepAlive stays false to avoid racing the updater.

        // Surface any prior-run OOM and react to live memory pressure. Best-effort.
        startMemoryProtection()
        // On any controlled exit (return/throw — i.e. NOT a jetsam SIGKILL),
        // drop a memory-pressure marker so a survived pressure spike isn't
        // misreported as an OOM next launch. A real kill bypasses this.
        defer {
            memoryPressureMonitor?.cancel()
            OOMDetector.clearMarker()
        }

        // Unified mode: also expose a local OpenAI endpoint off the same loaded
        // models. Started before the coordinator connection so local clients can
        // serve immediately; torn down on shutdown.
        if let localEndpoint = loopConfig.localEndpoint {
            startLocalEndpoint(localEndpoint)
        }
        defer { stopLocalEndpoint() }

        // 1. Apply security hardening
        try await applySecurityHardening()

        // Arm the loaded-models persistence now that this loop is actually
        // serving (test instances never flip this, so their unload paths
        // cannot clobber the real ~/.darkbloom/loaded-models.json).
        loadedModelsPersistenceEnabled = true

        // 1.5 Startup preload + readiness gate (ProviderLoop+StartupPreload):
        // load the previously-served / configured model set BEFORE the
        // coordinator client exists, so a release restart never advertises
        // models it hasn't warmed (the v0.6.30 first_chunk_timeout storm).
        // Bounded by startup_preload_timeout_secs — on timeout we register
        // anyway and the remaining loads continue in the background.
        await runStartupPreloadGate()

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

        // APNs code-identity (v0.6.0): wait briefly for the device token the app
        // delegate captures after registerForRemoteNotifications. Present only on
        // a logged-in macOS GUI session running under the AppKit host; a headless
        // / no-GUI box gets nil and registers un-attested (fail-closed at routing).
        var apnsDeviceToken: String?
        #if os(macOS)
        apnsDeviceToken = await APNsBridge.shared.awaitDeviceToken(timeoutSeconds: 10)
        if apnsDeviceToken == nil {
            logger.warning("no APNs device token (no GUI session / not push-provisioned) — registering un-attested")
        }
        #endif

        // 4. Create coordinator client config. The model list is filtered
        // through the live advertised set: identical to loopConfig.models at
        // defaults, minus any model the startup self-test retired when the
        // operator opted into startup_selftest_fail_closed.
        let registrationModels = loopConfig.models.filter { advertisedModels[$0.id] != nil }
        let coordinatorConfig = CoordinatorClientConfig(
            url: loopConfig.coordinatorURL,
            hardware: loopConfig.hardware,
            models: registrationModels,
            backendName: "mlx-swift",
            heartbeatInterval: TimeInterval(loopConfig.config.coordinator.heartbeatIntervalSecs),
            publicKey: keyPair.publicKeyBase64,
            walletAddress: nil,
            attestation: attestation,
            authToken: loopConfig.authToken,
            runtimeHashes: runtimeWithMetallib,
            modelHashes: loopConfig.modelHashes,
            privacyCapabilities: privacyCapabilitiesForRegistration(),
            privateOnly: loopConfig.config.coordinator.privateOnly,
            apnsDeviceToken: apnsDeviceToken,
            apnsEnvironment: apnsDeviceToken != nil ? "production" : nil
        )

        // 4. Create coordinator client and start connection
        let coordinator = CoordinatorClient(
            config: coordinatorConfig,
            stats: stats,
            state: state
        )
        coordinatorClient = coordinator
        // Seed the client with the current map: a model loaded before the
        // client existed (e.g. a local-endpoint request during startup) may
        // already have refreshed a hash, and registration must carry it.
        await coordinator.updateModelWeightHashes(liveModelHashes)

        let (events, sendFn) = await coordinator.start()
        // Wire the direct inference-chunk fast path (Optimizations 1-3) alongside
        // the control path. `chunkSender` is a nonisolated handle on the actor;
        // its connection sink is (re)bound per session inside the client.
        let send = SendHandle(sendFn, chunkSender: coordinator.chunkSender)

        // APNs code-identity (v0.6.0): answer pushed code-identity challenges by
        // decrypting E_K(nonce) with K and signing the nonce with the SE key, then
        // replying over THIS WebSocket. The app delegate delivers pushes via the
        // bridge; we hop into the actor to use K + the signer + this send handle.
        #if os(macOS)
        APNsBridge.shared.setPushHandler { [weak self] userInfo in
            // Extract the Sendable EncryptedPayload synchronously here so the
            // non-Sendable [String: Any] never crosses into the actor Task.
            guard let self, let challenge = ProviderLoop.extractCodeChallenge(userInfo) else { return }
            Task { await self.handleCodeChallenge(challenge, send: send) }
        }

        // If the device token wasn't ready at registration (APNs slow / GUI
        // session still coming up), keep watching: when it arrives, reconnect so
        // registration re-runs WITH the token. Otherwise the provider would stay
        // un-attested (and unroutable under enforcement) until the process restarts.
        if apnsDeviceToken == nil {
            let log = logger
            Task {
                if let late = await APNsBridge.shared.awaitDeviceToken(timeoutSeconds: 60) {
                    log.info("APNs device token arrived after registration — reconnecting to re-register with token")
                    await coordinator.refreshAPNsToken(late)
                }
            }
        }
        #endif

        // Retain the send handle and build the background prefetch coordinator
        // (Layer 3) so applyVerifiedPrefetch can emit a `models_update` over the
        // live connection without threading a handle through the prefetch
        // callbacks. (coordinatorClient was already retained above, at creation.)
        self.outboundSend = send
        self.prefetchCoordinator = makePrefetchCoordinator()

        // Start the idle-timeout monitor before processing events so that
        // a rogue model-load (e.g. during `attestation_challenge` priming)
        // followed by a long disconnect is still subject to the unload
        // timer.
        startIdleMonitor()
        startCapacityRefreshMonitor()
        startAutoUpdateMonitor()

        logger.info("Coordinator client started, entering event loop")

        // 5. Process events. Cancellation is used by schedule enforcement
        // and service shutdown. On cancellation we begin a graceful shutdown
        // that drains active inference *before* closing the coordinator socket,
        // so in-flight responses can still reach consumers while we wind down.
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

                case .prefetchModel(let modelId, let priority):
                    if isDrainingForUpdate {
                        sendDrainingPrefetchFailure(modelId: modelId, send: send)
                    } else {
                        staleDesiredPrefetches.remove(modelId)
                        await handlePrefetchModelRequest(modelId: modelId, priority: priority, send: send)
                    }

                case .desiredModels(let entries):
                    if isDrainingForUpdate {
                        // Keep only the latest push (desired state is
                        // declarative). A successful restart makes it moot —
                        // registration receives fresh desired state — but an
                        // aborted restart replays it via resumeServingAfterUpdate.
                        deferredDesiredModels = entries
                        logger.info("Deferring desired_models during update drain (\(entries.count) entr(ies)); replayed if the restart is aborted")
                    } else {
                        await reconcileDesiredModels(entries, send: send)
                    }

                case .trustStatus(let trustLevel, let status, let reason):
                    handleTrustStatus(trustLevel: trustLevel, status: status, reason: reason)
                }
            }
        } onCancel: {
            // SIGTERM / `darkbloom stop` / schedule-close cancels the run task.
            // Kick off the shared graceful shutdown, which drains in-flight
            // inference *before* the transport is torn down. The fall-through
            // below awaits the same memoized task, so the coordinator socket and
            // loaded models stay alive until the drain completes. The drain runs
            // inside an unstructured Task (created by `startShutdown`) that does
            // NOT inherit this cancellation, so `waitForInflightDrain` keeps
            // polling instead of bailing on `Task.isCancelled`.
            Task { await self.startShutdown(drainInflight: true) }
        }

        // The event stream ended. If the run task was cancelled (user stop /
        // restart / schedule close) we drain in-flight inference first; otherwise
        // (coordinator disconnect, stream finished on its own) we cancel promptly
        // because responses can no longer be delivered. Either way we await the
        // SINGLE shared shutdown task, so transport teardown and model unloading
        // happen only after the drain — never racing it.
        let runTaskCancelled = Task.isCancelled
        logger.info("Event stream ended, shutting down")
        await startShutdown(drainInflight: runTaskCancelled).value
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
        if let posture = securityPosture {
            return PrivacyCapabilities(
                textBackendInprocess: true,
                textProxyDisabled: true,
                pythonRuntimeLocked: false,
                dangerousModulesBlocked: false,
                sipEnabled: posture.sipEnabled,
                antiDebugEnabled: posture.antiDebugEnabled,
                coreDumpsDisabled: posture.coreDumpsDisabled,
                envScrubbed: posture.envScrubbed
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
            envScrubbed: false
        )
    }

    // MARK: - Runtime hashes

    /// Add the live mlx.metallib hash under template_hashes["mlx_metallib"]
    /// while preserving any caller-supplied template entries. Returns nil if
    /// the input was nil and no metallib could be located (so we don't
    /// fabricate an empty RuntimeHashes that would suppress legitimate
    /// nil-handling downstream).
    internal func augmentRuntimeHashesWithMetallib(
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

}
