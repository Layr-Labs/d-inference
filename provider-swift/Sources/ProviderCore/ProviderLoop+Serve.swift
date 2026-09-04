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
        // Retired-knob warnings are emitted once by `Start.run()`, before
        // the serving-mode split — see `RetiredKnobWarnings`. Doing it here
        // reached only the coordinator-serving modes.

        logger.info(.providerStarting)
        logger.info("Hardware: \(loopConfig.hardware.chipName), \(loopConfig.hardware.memoryGb) GB RAM, \(loopConfig.hardware.gpuCores) GPU cores")
        logger.info("Models: \(loopConfig.models.count) advertised")
        logger.info("Coordinator: \(loopConfig.coordinatorURL)")

        // Maintain the entire encrypted SSD-cache root even when no model is
        // loaded. This is metadata/file-only work: no weights or KV arrays are
        // constructed. It closes TTL and 20 GiB budget gaps for unloaded dirs.
        SSDPrefixCacheFactory.startWholeRootMaintenance()
        defer { SSDPrefixCacheFactory.stopWholeRootMaintenance() }

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

        // 1. Apply security hardening
        try await applySecurityHardening()

        // MTP catalog metadata is process-local. Give it one short, owned
        // prewarm before either startup preloads or the unified local endpoint
        // can perform the first normal cold target load. This never downloads
        // assistant bytes and fails open on timeout.
        await prewarmSpecDecCatalog()

        // Unified mode: also expose a local OpenAI endpoint off the same loaded
        // models. It starts after the bounded metadata prewarm, but still before
        // the coordinator connection, so local serving keeps coordinator
        // independence while a cached assistant can join the first target load.
        if let localEndpoint = loopConfig.localEndpoint {
            startLocalEndpoint(localEndpoint)
        }
        defer { stopLocalEndpoint() }

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
        //
        // Stamp a minimal daemon state FIRST: a freshly installed candidate
        // spends its whole preload window with no heartbeat otherwise, and
        // the watchdog would misread a long (operator-raised) preload as a
        // hung launch and charge a false start failure. The refresh task keeps
        // that stamp fresh for the WHOLE preload (a single stamp goes stale
        // after 90s, but the gate may defer for startup_preload_timeout_secs);
        // it is cancelled once the gate returns and the capacity loop takes over.
        writeDaemonState()
        let preloadLivenessRefresh = startPreloadLivenessRefresh()
        await runStartupPreloadGate()
        preloadLivenessRefresh.cancel()

        // 2. Hash the exact mlx.metallib the live process will load. The same
        // digest is sent as reported runtime evidence and embedded in the
        // Secure-Enclave-signed attestation below.
        let runtimeWithMetallib = augmentRuntimeHashesWithMetallib(loopConfig.runtimeHashes)

        // 3. Capture immutable claims, but re-sign a fresh timestamp for every
        // WebSocket registration/reconnect.
        let registrationAttestation = makeRegistrationAttestationProvider(
            runtimeHashes: runtimeWithMetallib)
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
            attestation: nil,
            registrationAttestation: registrationAttestation,
            authToken: loopConfig.authToken,
            runtimeHashes: runtimeWithMetallib,
            modelHashes: loopConfig.modelHashes,
            privacyCapabilities: privacyCapabilitiesForRegistration(),
            runtimeCapabilities: loopConfig.runtimeCapabilities,
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

        logger.info(.coordinatorClientStarted)

        // 5. Process events. Cancellation is used by schedule enforcement and
        // service shutdown (the serve command's SIGTERM/SIGINT trap).
        //
        // The consumer is an UNSTRUCTURED task, deliberately: an AsyncStream
        // iterated from a cancelled task returns nil at once and terminates
        // the stream, and `waitForInflightDrain` short-circuits under
        // cancellation — so a `for await` here would end the moment run()'s
        // task was cancelled, and the old onCancel closed the socket
        // immediately. The coordinator then flushed every in-flight request
        // as a 502 "provider disconnected" (a served fault on the stable
        // identity) while the detached generation tasks kept decoding into a
        // finished router. Instead, cancellation starts `beginShutdownDrain`
        // (refuse → drain → close) in its own non-cancelled task while this
        // consumer keeps answering the coordinator — routed requests bounce
        // with the slot_state 503 (`isShuttingDown` gate in the handler) so
        // they reroute instead of timing out, and cancels still land — until
        // the drain closes the link, which finishes `events` and ends the
        // consumer.
        await serveCoordinatorEvents(coordinator: coordinator, events: events, send: send)
    }

    /// Step 5 of `run()` and its teardown, split out so a test can drive the
    /// real cancellation path (cancel this task, observe refuse → drain →
    /// close, return) against the in-process mock coordinator without the
    /// hardening, preload and APNs steps that precede it in `run()`.
    internal func serveCoordinatorEvents(
        coordinator: CoordinatorClient,
        events: AsyncStream<CoordinatorEvent>,
        send: SendHandle
    ) async {
        let me = self
        let consumer = Task {
            for await event in events {
                await me.dispatchCoordinatorEvent(event, send: send)
            }
        }
        await withTaskCancellationHandler {
            await consumer.value
        } onCancel: {
            Task { await me.beginShutdownDrain(coordinator: coordinator) }
        }

        logger.info(.coordinatorEventStreamEnded)
        isShuttingDown = true
        // Quote path mirror (routing v2): a shutting-down provider quotes
        // `slot_state` rejections for the brief window the socket stays up.
        state.refusingNewWork = true
        idleMonitorTask?.cancel()
        // A pending post-retirement reconnect must not re-register a
        // session shutdown is closing (its shutdown check has a hop).
        pendingRetirementReconnect?.cancel()
        idleMonitorTask = nil
        capacityRefreshTask?.cancel()
        daemonStateLivenessTask?.cancel()
        daemonStateLivenessTask = nil
        trailingHeartbeatTask?.cancel()
        trailingHeartbeatTask = nil
        capacityRefreshTask = nil
        autoUpdateTask?.cancel()
        autoUpdateTask = nil
        // Cancel any scheduled desired-build prefetch retries before tearing
        // the prefetch subsystem down.
        for task in desiredPrefetchRetryTasks.values { task.cancel() }
        desiredPrefetchRetryTasks.removeAll()
        desiredPrefetchRetryAttempts.removeAll()
        await specDecFunnel.shutdown()
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

    // MARK: - Event dispatch

    /// One coordinator event, on the loop actor. Split out of `run()` so the
    /// shutdown-ordering tests drive the exact production consumer.
    internal func dispatchCoordinatorEvent(_ event: CoordinatorEvent, send: SendHandle) async {
        switch event {
        case .connected:
            logger.info(.coordinatorConnected)
            // The post-retirement reconnect's admission barrier
            // (see `fireRetirementReconnect`) lifts with the new
            // session: the register it carried excluded every
            // retired id, so routed work is safe to admit again.
            isReconnectingAfterRetirement = false

        case .disconnected:
            logger.warning(.coordinatorDisconnected)
            // Cancel all in-flight requests on disconnect -- the coordinator
            // will not route responses for a dead connection.
            await cancelAllInflight()

        case .inferenceRequest(
            let requestId, let ciphertext, let senderPublicKey,
            let cacheReceiptNonce, let cacheScope, let prefixCacheProtocol,
            let toolSchemaMetadataProtocol, let firstContentDeadline,
            let receivedAt,
            let profile
        ):
            await handleInferenceRequest(
                requestId: requestId,
                ciphertext: ciphertext,
                senderPublicKey: senderPublicKey,
                cacheReceiptNonce: cacheReceiptNonce,
                authenticatedCacheScope: cacheScope,
                prefixCacheProtocol: prefixCacheProtocol,
                toolSchemaMetadataProtocol: toolSchemaMetadataProtocol,
                firstContentDeadline: firstContentDeadline,
                receivedAt: receivedAt,
                profile: profile,
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

        case .codeAttestationResumeChallenge(let challenge):
            handleCodeChallenge(challenge, send: send)

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

    // MARK: - Graceful shutdown: refuse → drain → close

    /// Bound on the post-cancel wait for force-cancelled generation tasks to
    /// push their 499 terminals through the outbound router before the link
    /// closes. The cancel lands at the next step boundary; this only has to
    /// cover that plus one router hop.
    internal static let terminalFlushTimeout: Duration = .seconds(2)

    /// The cancellation-path shutdown, in the order the coordinator needs:
    /// stop admitting (routed requests bounce with the slot_state 503 and
    /// reroute; quotes refuse), let in-flight generations finish (bounded by
    /// `gracefulDrainTimeout`, force-cancelled past it with a short window
    /// for their terminals to flush), and only THEN send the goingAway close.
    /// Runs in a non-cancelled task started by run()'s cancellation handler;
    /// idempotent so a second cancellation (or the post-loop teardown) is a
    /// no-op. `coordinator.shutdown()` finishes the event stream, which ends
    /// run()'s consumer and lets its teardown proceed.
    internal func beginShutdownDrain(
        coordinator: CoordinatorClient,
        drainTimeout: Duration? = nil
    ) async {
        guard !shutdownDrainStarted else { return }
        shutdownDrainStarted = true
        // Process-global, before any suspension: the signal trap's
        // escalation reads it to tell "draining" from "the loop actor is
        // wedged and this never ran" (then it exits instead of lingering
        // until launchd's SIGKILL while heartbeats keep attracting work).
        GracefulShutdownProgress.markDrainStarted()
        // `shutdownDrainBound`: the graceful bound, clamped to the launchd
        // job's effective ExitTimeOut on boxes that never re-ran `start`.
        let drainTimeout = drainTimeout ?? shutdownDrainBound
        isShuttingDown = true
        // Quote path mirror (routing v2): quotes refuse with slot_state for
        // the window the socket stays up, exactly like the admission gate.
        state.refusingNewWork = true
        // Stamp `shutting_down` before the first suspension: a newcomer
        // taking the single-instance lock (`darkbloom start --foreground`
        // over this daemon) reads it to wait for the drain instead of
        // sending the second SIGTERM that would cut it.
        writeDaemonState()
        // An auto-update cycle still checking/staging/jittering must not
        // commit or restart during this shutdown: cancel it (it aborts at
        // its next cancellation check). A cycle already DRAINING is left to
        // finish its wait — cancelling it would short-circuit its
        // `waitForInflightDrain` and force-cancel the very work this drain
        // protects; the shutdown guards on commit/restart stop it instead.
        if updatePhase != .draining {
            autoUpdateTask?.cancel()
        }
        // Heartbeat mirror: every slot reported non-routable, one event
        // heartbeat now, so the coordinator stops routing here within a
        // heartbeat instead of bouncing requests off the 503 gate until the
        // close (up to the whole drain window).
        publishDrainingCapacity()
        let inflight = inflightTasks.count
        if inflight > 0 {
            logger.info("Shutdown requested: refusing new work; draining \(inflight) in-flight request(s) (bound \(drainTimeout.components.seconds)s) before closing the coordinator link")
        }
        let drained = await waitForInflightDrain(timeout: drainTimeout, reason: "shutdown")
        if !drained {
            logger.warning("Shutdown drain timed out after \(drainTimeout.components.seconds)s; cancelling \(inflightTasks.count) remaining request(s)")
            let stragglers = Array(inflightTasks.values)
            await cancelAllInflight()
            await Self.waitForTasksToSettle(stragglers, timeout: Self.terminalFlushTimeout)
        }
        await coordinator.shutdown()
    }

    /// Wait up to `timeout` for the given (already cancelled) tasks to finish.
    /// Awaiting a `Task.value` is not itself cancellable, so the waiting is
    /// done by side tasks that decrement a counter, and this polls it.
    nonisolated internal static func waitForTasksToSettle(
        _ tasks: [Task<Void, Never>], timeout: Duration
    ) async {
        guard !tasks.isEmpty else { return }
        let remaining = SettleCounter(tasks.count)
        for task in tasks {
            Task {
                await task.value
                remaining.decrement()
            }
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while remaining.value > 0, ContinuousClock.now < deadline {
            try? await taskSleep(.milliseconds(25))
        }
    }

    // MARK: - Security Hardening

    private func applySecurityHardening() async throws {
        #if !DEBUG
        let posture = collectSecurityPosture()
        guard let binaryHash = posture.binaryHash, !binaryHash.isEmpty else {
            logger.error("Security hardening failed: provider binary hash unavailable")
            throw ProviderLoopError.binaryHashUnavailable
        }
        self.securityPosture = posture
        self.binaryHash = binaryHash
        logger.info("Security posture collected: SIP=\(posture.sipEnabled), RDMA_disabled=\(posture.rdmaDisabled), SE=\(SecureEnclave.isAvailable)")
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

    private func makeRegistrationAttestationProvider(
        runtimeHashes: RuntimeHashes?
    ) -> @Sendable () -> RawJSON? {
        let builder = attestationBuilder
        let encryptionPublicKey = keyPair.publicKeyBase64
        let signedBinaryHash = binaryHash
        let chipFamily = loopConfig.hardware.chipFamily
        let capabilities = loopConfig.runtimeCapabilities
        let signedMetallibHash = runtimeHashes?.templateHashes["mlx_metallib"]
        return {
            guard let builder else { return nil }
            guard let jsonData = try? builder.buildAttestationJSON(
                encryptionPublicKey: encryptionPublicKey,
                binaryHash: signedBinaryHash,
                chipFamily: chipFamily,
                runtimeCapabilities: capabilities,
                metallibHash: signedMetallibHash
            ) else {
                return nil
            }
            return RawJSON(rawBytes: jsonData)
        }
    }

}

// MARK: - SettleCounter

/// Lock-boxed countdown for `ProviderLoop.waitForTasksToSettle`.
private final class SettleCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int

    init(_ count: Int) { remaining = count }

    var value: Int { lock.withLock { remaining } }

    func decrement() { lock.withLock { remaining -= 1 } }
}
