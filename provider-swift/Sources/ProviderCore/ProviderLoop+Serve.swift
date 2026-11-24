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
        nativePairConfigurationClosed = true
        if isClusterMember { try prepareClusterMemberControl() }
        defer {
            if isClusterMember {
                memberConnectionID = nil
                finishMemberRegistrationWait(ClusterMemberControlError.connectionEnded)
            }
        }
        startLifecycleMonitor()
        defer { lifecycleMonitorTask?.cancel(); lifecycleMonitorTask = nil; cancelAppAttestShadow(stopWorker: true); cancelAppAttestStallMonitor() }
        defer { refusalLiveness?.cancel() }
        // An add-on hold refuses inference but keeps this startup going; only
        // a stop, update or other service change ends it before registration.
        if servingDrain.refusingForServiceChange { return }
        // Retired-knob warnings are emitted once by `Start.run()`, before
        // the serving-mode split — see `RetiredKnobWarnings`. Doing it here
        // reached only the coordinator-serving modes.

        logger.info(.providerStarting)
        logger.info("Hardware: \(loopConfig.hardware.chipName), \(loopConfig.hardware.memoryGb) GB RAM, \(loopConfig.hardware.gpuCores) GPU cores")
        logger.info("Models: \(loopConfig.models.count) advertised")
        logger.info("Coordinator: \(loopConfig.coordinatorURL)")
        let usesHostServices = serveUsesHostServices && !isClusterMember

        // A persisted add-on hold must close admission before the local
        // endpoint or the startup preload could load a model. Its local socket
        // also answers the add-on app during a boot-security hold.
        startAddonHoldService()
        defer { stopAddonHoldService() }

        // 1. Apply security hardening. A boot-security refusal holds here,
        // before anything keeps the Mac awake, loads a model or connects. A
        // stop while the boot settings are read ends startup here too.
        let collected = try await applySecurityHardening()
        let bootSecurityRefusals = Self.bootSecurityHold(securityPosture)
        if !bootSecurityRefusals.isEmpty { await holdWithoutDarkbloomServing(bootSecurityRefusals) }
        if !collected || Task.isCancelled || servingDrain.refusingForServiceChange || !bootSecurityRefusals.isEmpty {
            guard await shutdownBeforeRegistration() else {
                throw InferenceError.modelLoadFailed("Native MiMo startup shutdown remains pending or requires process restart")
            }
            return
        }

        // Maintain the entire encrypted SSD-cache root even when no model is
        // loaded. This is metadata/file-only work: no weights or KV arrays are
        // constructed. It closes TTL and shared disk-budget gaps for unloaded dirs.
        if usesHostServices { SSDPrefixCacheFactory.startWholeRootMaintenance() }
        defer { if usesHostServices { SSDPrefixCacheFactory.stopWholeRootMaintenance() } }
        // A pair's records expire on the same schedule, on a pair's Macs too.
        if serveUsesHostServices { ClusterPrefixRecordExpiry.start() }
        defer { if serveUsesHostServices { ClusterPrefixRecordExpiry.stop() } }

        // Keep the network stack alive during sleep (coordinator socket, APNs).
        networkAssertion.acquire()
        defer { networkAssertion.release() }

        // Suppress App Nap for the lifetime of the serve loop. macOS throttles
        // "napping" background processes — Task.sleep-driven timers (heartbeat,
        // ping/pong) stop firing on schedule, the coordinator stops receiving
        // heartbeats and evicts us within 90s, and our own throttled ping takes
        // minutes to notice the dead socket: the connect→evict→reconnect churn.
        // .userInitiated suppresses App Nap; .idleSystemSleepDisabled keeps an
        // idle box awake while serving, on battery too (caffeinate -s is AC-only).
        var napAssertion: NSObjectProtocol? = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled,
                      .suddenTerminationDisabled, .automaticTerminationDisabled],
            reason: "Darkbloom provider serving inference / keeping the coordinator link alive")
        defer { if let napAssertion { ProcessInfo.processInfo.endActivity(napAssertion) } }

        // Crash recovery is owned by the WatchdogAgent (separate launchd job,
        // #315) — installed from the serve path, so it reaches auto-updated
        // installs too. KeepAlive stays false to avoid racing the updater.

        // Surface any prior-run OOM and react to live memory pressure. Best-effort.
        if usesHostServices { startMemoryProtection() }
        // On any controlled exit (return/throw — i.e. NOT a jetsam SIGKILL),
        // drop a memory-pressure marker so a survived pressure spike isn't
        // misreported as an OOM next launch. A real kill bypasses this.
        defer {
            memoryPressureMonitor?.cancel()
            if usesHostServices { OOMDetector.clearMarker() }
        }

        // MTP catalog metadata is process-local. Give it one short, owned
        // prewarm before either startup preloads or the unified local endpoint
        // can perform the first normal cold target load. This never downloads
        // assistant bytes and fails open on timeout. A control-only member
        // serves no solo target, so it fetches no catalog and upgrades nothing.
        if !isClusterMember { await prewarmSpecDecCatalog() }
        if Task.isCancelled || servingDrain.refusingForServiceChange {
            guard await shutdownBeforeRegistration() else {
                throw InferenceError.modelLoadFailed("Native MiMo startup shutdown remains pending or requires process restart")
            }
            return
        }
        if !isClusterMember {
            startMTPUpgradeMonitor()
            startModelRevisionMonitor()
        }

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
        // cannot clobber the real ~/.darkbloom/loaded-models.json). A
        // control-only member never persists solo residency.
        loadedModelsPersistenceEnabled = !isClusterMember
        if usesHostServices { verifiedWeightHashesFile = VerifiedWeightHashStore.path() }

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
        // A control-only member loads no solo models at startup or ever.
        if !isClusterMember { await runStartupPreloadGate() }
        preloadLivenessRefresh.cancel()
        if Task.isCancelled || servingDrain.refusingForServiceChange {
            guard await shutdownBeforeRegistration() else {
                throw InferenceError.modelLoadFailed("Native MiMo startup shutdown remains pending or requires process restart")
            }
            return
        }

        // Schedule loaded engines before opening the coordinator connection.
        // This is nonblocking; foreground work can still preempt calibration.
        await refreshModelCalibration()
        await updateAggregateCapacity()

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
        if usesHostServices {
            apnsDeviceToken = await APNsBridge.shared.awaitDeviceToken(timeoutSeconds: 10)
            if apnsDeviceToken == nil {
                logger.warning("no APNs device token — legacy code verification unavailable; awaiting coordinator authorization")
            }
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
            attestation: nil,
            registrationAttestation: registrationAttestation,
            authToken: loopConfig.authToken,
            runtimeHashes: runtimeWithMetallib,
            modelHashes: loopConfig.modelHashes,
            privacyCapabilities: privacyCapabilitiesForRegistration(),
            runtimeCapabilities: loopConfig.runtimeCapabilities,
            privateOnly: loopConfig.config.coordinator.privateOnly,
            apnsDeviceToken: apnsDeviceToken,
            apnsEnvironment: apnsDeviceToken != nil ? "production" : nil,
            idleUnloadMins: loopConfig.config.backend.idleTimeoutMins,
            autopilotInventory: loopConfig.autopilotInventory,
            executionRole: loopConfig.executionRole,
            // Only a member with an installed control claims a membership, and
            // the claim is derived from that control's own policy bytes.
            clusterMembership: try nativePairMemberControl?.installation.membership,
            pairServingGrantedModelIDs: loopConfig.pairServingGrantedModelIDs,
            memberNegotiationWindow: clusterMemberNegotiationWindow
        )

        // A termination received during the APNs/startup awaits can already
        // have drained a process that has no coordinator connection yet.
        if Task.isCancelled || servingDrain.refusingForServiceChange {
            guard await shutdownBeforeRegistration() else {
                throw InferenceError.modelLoadFailed("Native MiMo startup shutdown remains pending or requires process restart")
            }
            return
        }
        // 4. Create coordinator client and start connection
        publishModelAutopilotSnapshot()
        let fixedKey = keyPair
        let coordinator = CoordinatorClient(
            config: coordinatorConfig,
            stats: stats,
            state: state,
            appAttestResumeResponder: { challenge, nonce in
                try fixedKey.appAttestResumeResponse(to: challenge, clientNonce: nonce)
            }
        )
        // Installed before the first connection: each connection attaches it
        // only after TLS readiness and its nonce-bound acceptance (inside the
        // client); an ordinary WebSocket acknowledgment never activates it.
        if let nativePairMemberControl { try await coordinator.installNativePairMember(nativePairMemberControl) }
        // While startup couldn't read Secure Boot, every connection, the first
        // included, reads it again just before it connects and registers with
        // the result; a downgrade that read finds keeps this Mac from
        // registering. A policy startup read is final, so then connecting asks
        // nothing. A pair's member keeps its startup reading: its registration
        // runs on the pair's negotiation deadlines.
        if !isClusterMember, securityPosture?.bootSecurity.secureBoot == .unknown {
            await coordinator.setRegistrationPrivacyRefresh { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.privacyCapabilitiesBeforeConnecting()
            }
        }
        coordinatorClient = coordinator
        // Seed the client with the current map: a model loaded before the
        // client existed (e.g. a local-endpoint request during startup) may
        // already have refreshed a hash, and registration must carry it.
        await coordinator.updateModelWeightHashes(liveModelHashes)

        if Task.isCancelled || servingDrain.refusingForServiceChange {
            await coordinator.shutdown()
            guard await shutdownBeforeRegistration() else {
                throw InferenceError.modelLoadFailed("Native MiMo startup shutdown remains pending or requires process restart")
            }
            return
        }
        // A registration wait that began before the client existed keeps
        // the client's first reconnects inside it as well.
        await coordinator.setMemberRegistrationDeadline(memberRegistrationWaitDeadline)
        let (events, sendFn) = await coordinator.start()
        if Task.isCancelled || servingDrain.refusingForServiceChange {
            guard await shutdownBeforeRegistration() else {
                throw InferenceError.modelLoadFailed("Native MiMo startup shutdown remains pending or requires process restart")
            }
            return
        }
        // Wire the direct inference-chunk fast path (Optimizations 1-3) alongside
        // the control path. `chunkSender` is a nonisolated handle on the actor;
        // its connection sink is (re)bound per session inside the client.
        let send = SendHandle(sendFn, chunkSender: coordinator.chunkSender)

        // APNs code-identity (v0.6.0): answer pushed code-identity challenges by
        // decrypting E_K(nonce) with K and signing the nonce with the SE key, then
        // replying over THIS WebSocket. The app delegate delivers pushes via the
        // bridge; we hop into the actor to use K + the signer + this send handle.
        #if os(macOS)
        if usesHostServices {
            let pushHistory = apnsPushHistory
            APNsBridge.shared.trackDeviceToken(in: pushHistory)
            APNsBridge.shared.setPushHandler { [weak self] userInfo in
                // Receipt is recorded before any parsing or validation so doctor
                // and `push_history` can tell "never delivered" from "not answered".
                pushHistory.recordReceipt()
                // Extract the Sendable EncryptedPayload synchronously here so the
                // non-Sendable [String: Any] never crosses into the actor Task.
                guard let self, let challenge = ProviderLoop.extractCodeChallenge(userInfo) else { return }
                // Only a push-delivered challenge counts as a push reply; resume
                // challenges arrive over the WebSocket through the same handler.
                Task { await self.handleCodeChallenge(challenge, send: send, onWritten: { pushHistory.recordReply() }) }
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
                        await self.refreshAPNsAfterDrain(late)
                    }
                }
            }
        }
        #endif

        // Retain the send handle and build the background prefetch coordinator
        // (Layer 3) so applyVerifiedPrefetch can emit a `models_update` over the
        // live connection without threading a handle through the prefetch
        // callbacks. (coordinatorClient was already retained above, at creation.)
        self.outboundSend = send
        // A control-only member never downloads or swaps models autonomously.
        if !isClusterMember { self.prefetchCoordinator = makePrefetchCoordinator() }
        // Start the idle-timeout monitor before processing events so that
        // a rogue model-load (e.g. during `attestation_challenge` priming)
        // followed by a long disconnect is still subject to the unload
        // timer.
        // A control-only member holds no solo residency to unload, keeps the
        // empty capacity it published at preparation, never relaunches its
        // binary unattended and verifies no Autopilot candidates.
        if !isClusterMember {
            startIdleMonitor()
            startCapacityRefreshMonitor()
            startAutoUpdateMonitor()
            startAutopilotCandidateVerification()
        }

        logger.info(.coordinatorClientStarted)

        noteCoordinatorConnection(connected: false)

        // 5. The event reader outlives cancellation of the calling task.
        // Lifecycle shutdown closes admission and drains accepted work plus
        // terminal accounting before ending this stream.
        coordinatorEventLoopStarted = true
        let (workEvents, workContinuation) = AsyncStream<CoordinatorEvent>.makeStream()
        let workTask = Task {
            for await event in workEvents {
                // Only order-free events overtake a request waiting for its
                // model load (`ProviderLoop+WorkFIFO.swift`).
                if !event.overtakesReleasedAdmissions { await awaitReleasedAdmissions() }
                switch event {
                case .drainAck(let id):
                    await coordinator.completeDrainAcknowledgement(id)
                case .connected:
                    clearAutopilotControl()
                    logger.info(.coordinatorConnected)
                    // The post-retirement reconnect's admission barrier
                    // (see `requestPlannedReconnect`) lifts with the new
                    // session: the register it carried excluded every
                    // retired id, so routed work is safe to admit again.
                    finishPlannedReconnect()

                case .disconnected:
                    await handleCoordinatorDisconnected()

                case .inferenceRequest(
                    let requestId, let ciphertext, let senderPublicKey,
                    let cacheReceiptNonce, let cacheScope, let prefixCacheProtocol,
                    let cacheReceiptBoundaryMode, let cacheRepeatedPrefixTokens,
                    let toolSchemaMetadataProtocol, let firstContentDeadline,
                    let receivedAt,
                    let profile, let serviceReservationID, let promptWork,
                    let gemmaPromptContract, let frameCachePolicy
                ):
                    await admitInWorkFIFO(requestId: requestId, queuedBytes: ciphertext.count) { gate in
                        await self.handleInferenceRequest(
                            requestId: requestId,
                            ciphertext: ciphertext,
                            senderPublicKey: senderPublicKey,
                            cacheReceiptNonce: cacheReceiptNonce,
                            authenticatedCacheScope: cacheScope,
                            prefixCacheProtocol: prefixCacheProtocol,
                            cacheReceiptBoundaryMode: cacheReceiptBoundaryMode,
                            cacheRepeatedPrefixTokens: cacheRepeatedPrefixTokens,
                            toolSchemaMetadataProtocol: toolSchemaMetadataProtocol,
                            firstContentDeadline: firstContentDeadline,
                            receivedAt: receivedAt,
                            profile: profile,
                            serviceReservationID: serviceReservationID,
                            promptWork: promptWork,
                            gemmaPromptContract: gemmaPromptContract,
                            frameCachePolicy: frameCachePolicy,
                            send: send,
                            workFIFOGate: gate
                        )
                    }

                case .cancel, .attestationChallenge, .codeAttestationResumeChallenge,
                    .appAttestShadow, .trustStatus:
                    // Consumed by the connection-control reader below.
                    break

                case .runtimeOutdated(let mismatches):
                    logger.warning("Runtime outdated: \(mismatches.count) mismatch(es)")
                    for m in mismatches {
                        logger.warning("  \(m.component): expected=\(m.expected), got=\(m.got)")
                    }

                case .modelAutopilotControl(let control):
                    await handleAutopilotControl(control)
                case .modelAutopilot(let command):
                    handleModelAutopilot(command, send: send)

                case .loadModel(let modelId):
                    handleLoadModelRequest(modelId: modelId, send: send)

                case .prefetchModel(let modelId, let priority):
                    await handleCoordinatorPrefetch(modelId: modelId, priority: priority, send: send)

                case .desiredModels(let entries):
                    await handleDesiredModels(entries, send: send)

                }
            }
            // The consumer ends only after every admission it started.
            await awaitReleasedAdmissions()
        }
        let eventTask = Task {
            // Model admission, hashing and cancellation may suspend for longer
            // than an attestation exchange. Read connection controls separately
            // so a healthy socket can renew trust while that work is parked.
            // All fast handlers are synchronous on this actor; connection
            // invalidation therefore precedes the next session's challenge.
            // Challenges and cancels are read here too: work ahead of them in
            // the FIFO can wait as long as a pair's rank reservation (30 s).
            for await event in events {
                // Member-mode events are consumed first: ordinary dispatch
                // paths never see them, and direct work handlers refuse
                // member mode independently.
                if consumeClusterMemberEvent(event, send: send) { continue }
                if memberControlRequiresStop {
                    // The accepted control connection ended or lost trust.
                    // End the loop instead of reconnecting under a new nonce.
                    await coordinator.shutdown()
                    break
                }
                switch event {
                case .appAttestShadow(let payload, let reply):
                    handleAppAttestShadow(payload, reply: reply)
                    continue
                case .trustStatus(let level, let status, let reason, let authorization):
                    handleTrustStatus(trustLevel: level, status: status, reason: reason,
                                      authorization: authorization)
                    continue
                case .attestationChallenge(let nonce, let timestamp):
                    handleAttestationChallenge(nonce: nonce, timestamp: timestamp, send: send)
                    continue
                case .codeAttestationResumeChallenge(let challenge):
                    handleCodeChallenge(challenge, send: send)
                    continue
                case .cancel(let requestId, let reason):
                    routeCoordinatorCancel(requestId, reason: reason)
                    continue
                case .connected, .disconnected:
                    noteCoordinatorConnection(connected: event.isConnected)
                    clearConnectionAuthorization()
                    cancelAppAttestShadow()
                case .inferenceRequest(
                    let requestId, let ciphertext, _, _, _, _, _, _, _, _, _, let profile, let serviceReservationID, _, _, _
                ):
                    // Here, not in the work reader: on arrival, in order with
                    // the trust statuses `ServingReadiness` compares it to.
                    // A request refused below was routed here all the same.
                    noteCoordinatorRequest()
                    guard queueCoordinatorAdmission(requestId, bytes: ciphertext.count) else {
                        refuseCoordinatorRequestPastQueueBudget(
                            requestId, profile: profile, serviceReservationID: serviceReservationID, send: send)
                        continue
                    }
                default:
                    break
                }
                // Slow work keeps its original FIFO ordering, including
                // disconnect cleanup before the next connection's work.
                workContinuation.yield(event)
            }
            noteCoordinatorConnection(connected: false)
            clearConnectionAuthorization()
            cancelAppAttestShadow()
            workContinuation.finish()
            await workTask.value
        }
        await withTaskCancellationHandler {
            await eventTask.value
        } onCancel: {
            Task {
                if await self.drainAndShutdown(timeoutSeconds: ProviderTermination.timeoutSeconds) { return }
                await self.shutdownStoppedClusterMember()
            }
        }

        clearConnectionAuthorization()
        logger.info(.coordinatorEventStreamEnded)
        isShuttingDown = true
        if isClusterMember {
            // No grant or key is retained across a control connection boundary.
            memberConnectionID = nil
            state.refusingNewWork = true
            cancelMeFirstResumeTimer()
            // A refused or unanswered negotiation ended the client: a waiting
            // start reports that, not a plain connection end.
            let roleRefused = await coordinator.memberRoleFailure
            let roleUnsupported = await coordinator.memberRoleUnsupported
            let roleError: ClusterMemberControlError = roleUnsupported ? .roleUnsupported : .negotiationFailed
            finishMemberRegistrationWait(roleRefused ? roleError : ClusterMemberControlError.connectionEnded)
            // The pair slot's engine shuts its owner down, so both ranks end
            // their work and each member's owner can release its device.
            await retireClusterPairSlot(reason: "member stopping")
            await coordinator.shutdown()
            if await coordinator.memberRoleFailure {
                throw await coordinator.memberRoleUnsupported ? ClusterMemberControlError.roleUnsupported
                                                               : ClusterMemberControlError.negotiationFailed
            }
            return
        }
        closeNativeMiMoLifecycle() // close native generation before teardown awaits
        await cancelModelSwitchAndWait()
        // Quote path mirror (routing v2): a shutting-down provider quotes
        // `slot_state` rejections for the brief window the socket stays up.
        state.refusingNewWork = true
        idleMonitorTask?.cancel()
        // A pending post-retirement reconnect must not re-register a
        // session shutdown is closing (its shutdown check has a hop).
        pendingRetirementReconnect?.cancel()
        idleMonitorTask = nil
        cancelMeFirstResumeTimer()
        capacityRefreshTask?.cancel()
        await stopServiceAllowanceRefreshMonitor()
        await stopPerformanceRefreshMonitor()
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
        modelRevisionMonitorTask?.cancel()
        modelRevisionAttempt?.task.cancel()
        await modelRevisionMonitorTask?.value
        modelRevisionMonitorTask = nil
        let mtpUpgradeTask = mtpUpgradeMonitorTask
        mtpUpgradeMonitorTask = nil
        mtpUpgradeTask?.cancel()
        await specDecFunnel.shutdown()
        await mtpUpgradeTask?.value
        // Cancel background prefetch downloads (no GPU slot, but they hold a
        // network connection and disk staging we want to release promptly).
        if let prefetchCoordinator {
            await prefetchCoordinator.shutdown(timeout: Self.preloadShutdownTimeout)
        }
        if let autopilotDownloadCoordinator {
            await autopilotDownloadCoordinator.shutdown(timeout: Self.preloadShutdownTimeout)
        }
        autopilotCandidateVerification?.cancel()
        // Cancel BOTH preload flavors: coordinator-driven load_model tasks and
        // any still-running startup preload driver (it outlives the readiness
        // gate when the timeout passed).
        var preloads = Array(preloadTasks.values)
        if let autopilotTask { preloads.append(autopilotTask) }
        if let recovery = selectedModelRecovery.attempt?.task { preloads.append(recovery) }
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
            await cancelAllInflight(cause: .stoppedOnThisMac)
        }
        await coordinator.shutdown()
        let nativeOwnersDrained = await nativeOwnersRetired()
        // A boot-settings refusal found before a connection ended the client, and serving ended above as at a stop;
        // the service then holds as one refused at startup does. Native owners still pending stay retained and
        // loaded then, for the stop that ends the hold to drain (its drain succeeds only once they are).
        guard nativeOwnersDrained || refusalsBeforeConnecting != nil else {
            // Real registry/slot/consumer owners stay reachable. A pending or
            // faulted native engine is not an empty successful shutdown.
            throw InferenceError.modelLoadFailed("Native MiMo slot shutdown remains pending or requires process restart")
        }
        if nativeOwnersDrained { await unloadAllModelsForShutdown() }
        powerAssertion.releaseAll()
        if let refusals = refusalsBeforeConnecting {
            if !Task.isCancelled {
                // What only serving needed goes before the hold: the local API, keeping the Mac awake and the
                // network assertion.
                stopLocalEndpoint()
                if let assertion = napAssertion { ProcessInfo.processInfo.endActivity(assertion) }
                napAssertion = nil
                networkAssertion.release()
            }
            await holdAfterRefusal(refusals)
            // This process may serve again (a scheduled window) only once the native owners the teardown left
            // pending are retired, and after the unload it skipped then. Still pending, this ends as a stop does
            // with them pending: a process restart is needed.
            if !nativeOwnersDrained {
                guard await nativeOwnersRetired() else {
                    throw InferenceError.modelLoadFailed("Native MiMo slot shutdown remains pending or requires process restart")
                }
                await unloadAllModelsForShutdown()
            }
        }
    }

    // MARK: - Security Hardening

    /// False when a stop, update or other service change began while the boot
    /// settings were read: then nothing more was read or hardened, no posture
    /// is adopted, and startup ends.
    private func applySecurityHardening() async throws -> Bool {
        let stop: @Sendable () async -> Bool = { [weak self] in await self?.stopsStartupSecureBootReads() ?? true }
        #if !DEBUG
        guard let posture = await collectSecurityPosture(secureBootRetry: secureBootReadRetry, secureBootStop: stop)
        else { return false }
        try adoptSecurityPosture(posture)
        #else
        if let reading = bootSettingsReadingOverride {
            // A test's stand-in boot-settings results: the release collection and adoption, without hardening the
            // shared test process.
            guard let posture = await collectSecurityPostureWithoutHardening(
                bootSettingsCommands: reading.commands, kernelSIP: { reading.kernelSIP },
                secureBootRetry: secureBootReadRetry, secureBootStop: stop)
            else { return false }
            try adoptSecurityPosture(posture)
        } else {
            logger.info("Security hardening skipped in DEBUG mode")
            self.binaryHash = selfBinaryHash()
        }
        #endif
        return true
    }

    private func adoptSecurityPosture(_ posture: SecurityPosture) throws {
        guard let binaryHash = posture.binaryHash, !binaryHash.isEmpty else {
            logger.error("Security hardening failed: provider binary hash unavailable")
            throw ProviderLoopError.binaryHashUnavailable
        }
        self.securityPosture = posture
        self.binaryHash = binaryHash
        logger.info("Security posture collected: SIP=\(posture.sipEnabled), RDMA_disabled=\(posture.rdmaDisabled), SE=\(SecureEnclave.isAvailable)")
    }

    private func privacyCapabilitiesForRegistration() -> PrivacyCapabilities {
        Self.registrationPrivacyCapabilities(securityPosture)
    }

    /// The gate before any preload or coordinator connection: the boot-settings
    /// refusals this posture holds for (empty: serve). Shared with the collector
    /// fixture, so its test exercises the loop's own decision.
    public static func bootSecurityHold(_ posture: SecurityPosture?) -> [BootSecurityIssue] {
        posture?.bootSecurity.servingRefusals ?? []
    }

    /// The registration's `privacy_capabilities` for this posture. Shared with the
    /// collector fixture, so its test reads the loop's own wire report.
    public static func registrationPrivacyCapabilities(
        _ posture: SecurityPosture?, servingVolume: ServingVolumeCheck.Verdict = ServingVolumeCheck.liveAtStart
    ) -> PrivacyCapabilities {
        // textBackendInprocess + textProxyDisabled: always true on the Swift
        //   provider -- inference runs in-process via mlx-swift-lm, no HTTP
        //   proxy is involved.
        let capabilities = PrivacyCapabilities(
            textBackendInprocess: true,
            textProxyDisabled: true,
            sipEnabled: posture?.sipEnabled ?? SecurityChecks.isSIPEnabled(),
            antiDebugEnabled: posture?.antiDebugEnabled ?? false,
            coreDumpsDisabled: posture?.coreDumpsDisabled ?? false,
            envScrubbed: posture?.envScrubbed ?? false,
            servingVolume: servingVolume.reportedClass
        )
        guard let bootSecurity = posture?.bootSecurity else { return capabilities }
        return capabilities.reportingBootSecurity(bootSecurity)
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
