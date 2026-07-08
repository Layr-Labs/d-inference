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
        // v0.7.5 one-engine: the v2 selection knobs are retired — warn
        // operators still setting them so nobody believes a kill switch
        // exists that doesn't. Selection is unconditional; rollback is
        // release-level.
        for retired in EngineV2Config.retiredEnvironmentKeysSet() {
            logger.warning(
                "\(retired) is retired and IGNORED as of v0.7.5 — the v2 engine serves "
                    + "everything; rollback is release-level, not a per-box switch")
        }
        if loopConfig.config.backend.engineV2 == false {
            logger.warning(
                "provider.toml sets engine_v2 = false, which is retired and IGNORED as of "
                    + "v0.7.5 — the v2 engine serves everything; remove the key")
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
        // Cancel any scheduled desired-build prefetch retries before tearing
        // the prefetch subsystem down.
        for task in desiredPrefetchRetryTasks.values { task.cancel() }
        desiredPrefetchRetryTasks.removeAll()
        desiredPrefetchRetryAttempts.removeAll()
        // Cancel background prefetch downloads (no GPU slot, but they hold a
        // network connection and disk staging we want to release promptly).
        if let prefetchCoordinator {
            await prefetchCoordinator.shutdown(timeout: Self.preloadShutdownTimeout)
        }
        // Cancel BOTH preload flavors: coordinator-driven load_model tasks and
        // any still-running startup preload driver (it outlives the readiness
        // gate when the timeout passed).
        var preloads = Array(preloadTasks.values)
        if let startupTask = startupPreloadTask {
            preloads.append(startupTask)
        }
        for task in preloads { task.cancel() }
        cancelLoadWaiters()
        let preloadsFinished = await waitForPreloads(preloads, timeout: Self.preloadShutdownTimeout)
        if !preloadsFinished {
            logger.warning("Timed out waiting for coordinator-driven preloads to cancel during shutdown")
        }
        startupPreloadTask = nil
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
