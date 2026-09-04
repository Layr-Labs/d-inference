// Start serving modes: --local standalone, launchd-foreground (coordinator +
// optional unified local endpoint), startup auto-update, and scheduled windows.
import Foundation
import ArgumentParser
import ProviderCore
#if canImport(Darwin)
import Darwin
#endif

extension Start {
    // MARK: - Standalone (--local)

    internal func runLocalStandalone(
        snapshot: RuntimeSnapshot,
        config: ProviderConfig,
        hardware: HardwareInfo,
        runtimeCapabilities: Set<ProviderRuntimeCapability>,
        bootSecuritySnapshot: BootSecuritySnapshot = .live()
    ) async throws {
        warnBootSecurity(snapshot: bootSecuritySnapshot, coordinatorEnforced: false)

        let selected = advertisedModels(
            from: snapshot.models,
            config: config,
            modelOverrides: model,
            includeDisabled: all,
            runtimeCapabilities: runtimeCapabilities
        )

        // v0.7.5 ONE ENGINE, fail loud: the standalone server serves
        // everything through ContinuousBatchingV2, so a model whose family
        // has no CBv2 adapter cannot serve at all. Say so per model, and
        // refuse to start when nothing serveable remains — a silent empty
        // catalog would 404 every request with no explanation.
        let (advertised, unsupported) = EngineV2SupportedModels.partition(selected)
        for dropped in unsupported {
            printError(
                "Skipping \(dropped.id): model_type '\(dropped.modelType ?? "unknown")' has no "
                    + "engine-v2 adapter (v0.7.5 serves everything through engine v2)")
        }
        guard !advertised.isEmpty else {
            printError(
                "No engine-v2-capable models available to serve. "
                    + "Download a supported model (gpt-oss / gemma-4 families) and retry.")
            throw ExitCode.failure
        }

        // Direct/local mode: mint (or reuse) a bearer token so the loopback
        // server isn't open to every local process / hostile webpage. --no-auth
        // opts out for trusted/airgapped use.
        let token: String?
        if noAuth {
            token = nil
        } else {
            token = try LocalEndpoint.loadOrCreateToken()
        }

        let baseURL = "http://\(bind == "0.0.0.0" ? "127.0.0.1" : bind):\(port)/v1"
        print("darkbloom \(ProviderCore.version) (local / direct mode)")
        print("Listening on \(bind):\(port)")
        print("Models: \(advertised.count)")
        for m in advertised {
            print("  \(m.id) (\(String(format: "%.1f", m.estimatedMemoryGb)) GB)")
        }
        print()
        print("OpenAI-compatible endpoint:")
        print("  base URL: \(baseURL)")
        if let token {
            print("  API key:  \(token)")
            print()
            print("  export OPENAI_BASE_URL=\(baseURL)")
            print("  export OPENAI_API_KEY=\(token)")
        } else {
            print("  API key:  (auth disabled — --no-auth)")
        }
        print()
        print("  Shareable any time with: darkbloom local")
        print()

        // Lock acquisition and exact legacy-artifact housekeeping are one
        // ordered operation shared with coordinator-connected foreground mode.
        try ProcessLifecycle.acquireMediaServingLock()
        ProcessLifecycle.preventSystemSleep()
        defer { ProcessLifecycle.releaseSingleInstanceLock() }

        // NOTE: no LegacyCompiledDecodeGate here anymore — the standalone
        // server constructs no legacy engine as of v0.7.5 (CBv2 compiled
        // decode has its own path and needs no process-global latch).
        let server = StandaloneServer(
            config: StandaloneServerConfig(
                port: port,
                host: bind,
                maxCachedModels: Int(clamping: config.backend.maxModelSlots),
                authToken: token,
                hardware: hardware,
                runtimeCapabilities: runtimeCapabilities,
                engineV2MaxConcurrent: config.backend.engineV2MaxConcurrent,
                engineV2MaxConcurrentByModel: config.backend.engineV2MaxConcurrentByModel,
                engineV2KVBackend: config.backend.engineV2KVBackend,
                engineV2KVBackendByModel: config.backend.engineV2KVBackendByModel,
                prefillDeadlineMode: config.backend.prefillDeadlineMode,
                mtpMode: config.backend.mtpMode,
                mtpDrafterPath: config.backend.mtpDrafterPath
            ),
            models: advertised
        )
        try await server.start()

        // Wait until the server CONFIRMS it bound the port before advertising it.
        // start() launches Hummingbird in a child task and returns before the
        // bind completes; we must not write a discovery record pointing at a dead
        // (or, worse, a foreign) endpoint that `darkbloom local` / local-first
        // clients would then trust. waitUntilBound reads the actor's own bind
        // signal (Hummingbird onServerRunning), not an HTTP probe a process
        // already holding the port could answer.
        guard await server.waitUntilBound(timeoutSeconds: 5.0) else {
            await server.stop()
            printError("Local server failed to bind \(bind):\(port) within 5s — is the port already in use?")
            throw ExitCode.failure
        }

        // Publish discovery metadata so a same-machine client (and
        // `darkbloom local`) can find + authenticate to this server. Removed on
        // exit; the token file persists so the token survives restarts.
        let info = LocalEndpoint.Info(
            host: bind,
            port: port,
            apiKey: token ?? "",
            version: ProviderCore.version,
            pid: ProcessInfo.processInfo.processIdentifier,
            updatedAt: ISO8601DateFormatter().string(from: Date())
        )
        try? LocalEndpoint.writeInfo(info)
        defer { LocalEndpoint.removeInfo() }

        // The optional fan helper receives a renewable activity lease only
        // after the server has successfully bound, and only for the lifetime
        // of the actual Hummingbird service task. A stopped/crashed local
        // server therefore releases fan control.
        await withFanActivityLease(providerVersion: ProviderCore.version) {
            await server.waitUntilStopped()
        }
    }


    // MARK: - Foreground (invoked by launchd)

    internal func runForeground(
        snapshot: RuntimeSnapshot,
        hardware: HardwareInfo,
        config: ProviderConfig,
        coordinatorURL: String,
        runtimeCapabilities: Set<ProviderRuntimeCapability>,
        bootSecuritySnapshot: BootSecuritySnapshot = .live()
    ) async throws {
        warnBootSecurity(snapshot: bootSecuritySnapshot, coordinatorEnforced: true)

        let selectedModels: [ModelInfo]
        if !model.isEmpty {
            selectedModels = advertisedModels(
                from: snapshot.models,
                config: config,
                modelOverrides: model,
                runtimeCapabilities: runtimeCapabilities)
        } else if all {
            selectedModels = snapshot.models.filter {
                ModelRuntimeRequirements.isEligible(
                    modelID: $0.id, available: runtimeCapabilities)
            }
        } else {
            selectedModels = advertisedModels(
                from: snapshot.models,
                config: config,
                runtimeCapabilities: runtimeCapabilities)
        }

        guard !selectedModels.isEmpty else {
            printError("No models selected.")
            throw ExitCode.failure
        }

        let runtimeHashes = (try? RuntimeHashReporter().report().coordinatorRuntimeHashes)
        let authToken = AuthTokenStore.load()
        if let identity = ProcessIdentity.current() {
            try? SelfUpdater(
                coordinatorBaseURL: coordinatorURL
            ).confirmRunningCandidateLaunch(
                processStartedAt: Double(identity.startTimeMicros) / 1_000_000
            )
        }

        // Update check BEFORE the startup weight-hash pass (T4-02): on
        // `.updated`/`.restartRequired` the updater execs the new binary,
        // which used to discard a finished full SHA-256 pass over every
        // advertised model (12-60 s per release-day restart, paid twice).
        // Nothing between the two consumed the hashes. `StartupHashOrdering`
        // pins the order so it cannot silently regress.
        let (models, modelHashes, modelHashFingerprints) = try await StartupHashOrdering.run(
            checkForUpdate: {
                if config.provider.autoUpdate {
                    try await runStartupAutoUpdate(coordinatorURL: coordinatorURL)
                }
            },
            hashModels: { attachWeightHashes(to: selectedModels) })

        // ----- Process lifecycle: PID lock, legacy-artifact housekeeping, caffeinate. -----
        // Housekeeping runs once here, outside telemetry configuration and any
        // scheduled ProviderLoop reconstruction, after the old process releases the lock.
        try ProcessLifecycle.acquireMediaServingLock()
        ProcessLifecycle.preventSystemSleep()
        defer { ProcessLifecycle.releaseSingleInstanceLock() }

        // Housekeeping has removed the legacy telemetry queue. Install the
        // panic hook now; its compatibility queue calls are no-ops and its only
        // provider-owned output is a bounded local stderr marker.
        PanicHook.install()
        // CBV2_STEP_PROFILE=1 only: SIGUSR1 dumps the engine step-phase table.
        EngineStepProfileDump.armIfEnabled()

        // Arm crash recovery for the running daemon however it was launched
        // (manual start, login, or auto-update relaunch). Idempotent (skip when
        // already loaded → no churn on restarts) + best-effort.
        if config.provider.autoRestart, !WatchdogAgent.isLoaded() {
            try? WatchdogAgent.installAndStart(
                configPath: snapshot.configPath
            )
        }

        // A crash-loop KV-backend guard binds only the binary version that
        // tripped it, and a NEW version booting here is the fleet's
        // fix-delivery event. The version check in the engine factory
        // already keeps a mismatched record inert; deleting it too keeps
        // `status`/`doctor` from describing a guard that can never bind
        // again. A matching record is deliberately left alone — this
        // binary tripped it, so `.auto` keeps resolving contiguous.
        if let cleared = KVBackendGuardStore.clearIfStale(
            runningVersion: ProviderCore.version)
        {
            print(
                "Cleared stale crash-loop KV-backend guard from "
                    + "v\(cleared.providerVersion) (this binary is "
                    + "v\(ProviderCore.version)); backend selection resolves "
                    + "normally again.")
        }

        // ----- Telemetry: configure now so reconnect/inference/panic events flow. -----
        TelemetryClient.shared.configure(TelemetryClientConfig(
            coordinatorURL: coordinatorURL,
            source: .provider,
            authToken: authToken,
            version: ProviderCore.version
        ))

        var startupFields = bootSecurityTelemetryFields(bootSecuritySnapshot)
        startupFields["backend"] = .string("mlx-swift")

        TelemetryClient.shared.emit(
            kind: .log,
            severity: bootSecuritySnapshot.issues.isEmpty ? .info : .warn,
            message: "provider starting",
            fields: startupFields
        )

        let schedule: Schedule? = config.schedule.flatMap { Schedule.from(config: $0) }

        // launchd's SIGTERM→SIGKILL budget for THIS job, read from the loaded
        // definition: the drain is clamped below it, and an install whose
        // plist predates `ExitTimeOut` (auto-updated boxes) is reconciled on
        // disk so the next bootstrap carries the intended value.
        let launchdExitTimeOut = LaunchAgent.loadedExitTimeOutSeconds()
        if launchdExitTimeOut != nil, LaunchAgent.isInstalled(),
           LaunchAgent.reconcileExitTimeOutOnDisk()
        {
            print("Updated the launchd plist's ExitTimeOut to \(LaunchAgent.exitTimeOutSeconds)s (takes effect at the next login, reboot or `darkbloom start`).")
        }

        print("darkbloom \(ProviderCore.version)")
        print("Backend: mlx-swift")
        // Engine env this process runs with (launchd replays the plist's
        // persisted keys on every restart/recovery): in the provider log so
        // a persisted profiler/opt-out is not silent.
        let engineEnv = LaunchAgent.persistedInferenceEnvironment(
            from: ProcessInfo.processInfo.environment)
        if !engineEnv.isEmpty {
            print("Engine env: \(engineEnv.joined(separator: " "))")
        }
        print("Config: \(describeConfigPath(snapshot))")
        print("Coordinator: \(coordinatorURL)")
        if let schedule {
            print("Schedule: \(schedule.describe())")
        } else {
            print("Schedule: always available")
        }
        print("Advertised models: \(models.count)")
        for m in models {
            print("  \(m.id) (\(String(format: "%.1f", m.estimatedMemoryGb)) GB)")
        }

        // Unified mode: build the local-endpoint config when --local-endpoint is
        // set. Reuses the same persistent bearer token + bind/port options as
        // --local; --no-auth opts out of the token (trusted/airgapped only).
        var localEndpointConfig: LocalInferenceHTTPConfig?
        if localEndpoint {
            // FAIL CLOSED: if auth is requested (no --no-auth) but the token
            // can't be created/read, abort rather than silently opening the
            // endpoint unauthenticated — otherwise an unwritable ~/.darkbloom
            // would expose it (especially under --bind 0.0.0.0). Mirrors --local.
            let token: String?
            if noAuth {
                token = nil
            } else {
                do {
                    token = try LocalEndpoint.loadOrCreateToken()
                } catch {
                    printError("Cannot start --local-endpoint: failed to create the local API token (\(error)). Fix ~/.darkbloom permissions, or pass --no-auth for a trusted/airgapped setup.")
                    throw ExitCode.failure
                }
            }
            localEndpointConfig = LocalInferenceHTTPConfig(host: bind, port: port, authToken: token)
            let shownURL = "http://\(bind == "0.0.0.0" ? "127.0.0.1" : bind):\(port)/v1"
            print("Local endpoint: \(shownURL)\(token != nil ? "  (API key from `darkbloom local`)" : "  (auth disabled)")")
        }

        let loopConfig = ProviderLoopConfig(
            coordinatorURL: coordinatorURL,
            hardware: hardware,
            models: models,
            config: config,
            authToken: authToken,
            runtimeHashes: runtimeHashes,
            runtimeCapabilities: runtimeCapabilities,
            modelHashes: modelHashes,
            modelHashFingerprints: modelHashFingerprints,
            localEndpoint: localEndpointConfig
        )

        do {
            try await runUntilTerminationSignal {
                if let schedule {
                    try await runScheduled(
                        loopConfig: loopConfig, schedule: schedule,
                        launchdExitTimeOut: launchdExitTimeOut)
                } else {
                    let loop = try ProviderLoop(config: loopConfig)
                    await loop.clampShutdownDrain(toLaunchdExitTimeOut: launchdExitTimeOut)
                    try await runProviderLoopWithFanLease(loop)
                }
            }
        } catch {
            TelemetryClient.shared.emit(
                kind: .log,
                severity: .error,
                message: "provider loop terminated: \(error.localizedDescription)"
            )
            throw error
        }

        await TelemetryClient.shared.shutdown()
    }

    private func runStartupAutoUpdate(coordinatorURL: String) async throws {
        if ProcessInfo.processInfo.environment["DARKBLOOM_NO_UPDATE_CHECK"] != nil {
            return
        }
        print("Checking for provider update...")
        // Bounded network: this runs before the PID lock and the preload, and
        // `.shared`'s 7-day resource timeout could otherwise park a cold start
        // on a stalled download for as long as the operator waits.
        let updater = SelfUpdater.forDaemon(coordinatorBaseURL: coordinatorURL)
        switch await updater.update() {
        case .alreadyUpToDate:
            return
        case .updated(let from, let to):
            print("Updated provider: v\(from) -> v\(to). Restarting into new binary...")
            do {
                try updater.prepareCandidateLaunch(
                    operation: "startup-update-exec"
                )
                try ProcessLifecycle.execCurrentProcess()
            } catch {
                try? updater.cancelPendingCandidateAttempt(
                    operation: "startup-exec-failure")
                throw error
            }
        case .restartRequired(let from, let to):
            print("Provider v\(to) is already installed (running v\(from)); restarting into it...")
            do {
                try updater.prepareCandidateLaunch(
                    operation: "startup-candidate-exec"
                )
                try ProcessLifecycle.execCurrentProcess()
            } catch {
                try? updater.cancelPendingCandidateAttempt(
                    operation: "startup-exec-failure")
                throw error
            }
        case .quarantined(let version, let reason):
            printError("auto-update skipped: v\(version) is quarantined after failed starts (\(reason))")
        case .busy(let reason):
            printError("auto-update skipped: another update/recovery operation is active (\(reason))")
        case .cancelled(let reason):
            printError("auto-update cancelled: \(reason)")
        case .downloadFailed(let reason):
            printError("auto-update skipped: \(reason)")
        case .hashMismatch(let expected, let got):
            printError("auto-update skipped: bundle hash mismatch (expected \(expected), got \(got))")
        case .replaceFailed(let reason):
            printError("auto-update skipped: \(reason)")
        }
    }

    private enum ScheduledLoopResult {
        case loopEnded
        case windowClosed
    }

    private func runScheduled(
        loopConfig: ProviderLoopConfig,
        schedule: Schedule,
        launchdExitTimeOut: Int?
    ) async throws {
        while !Task.isCancelled {
            if !schedule.isActiveNow() {
                let wait = schedule.durationUntilNextActive()
                print("Outside availability schedule; next window opens in \(formatDuration(wait)).")
                try await Task.sleep(nanoseconds: sleepNanoseconds(for: wait))
                continue
            }

            let activeFor = schedule.durationUntilInactive() ?? 3600
            print("Availability window active for \(formatDuration(activeFor)).")

            let loop = try ProviderLoop(config: loopConfig)
            await loop.clampShutdownDrain(toLaunchdExitTimeOut: launchdExitTimeOut)
            try await withThrowingTaskGroup(of: ScheduledLoopResult.self) { group in
                group.addTask {
                    try await runProviderLoopWithFanLease(loop)
                    return .loopEnded
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: sleepNanoseconds(for: activeFor))
                    return .windowClosed
                }

                guard let result = try await group.next() else { return }
                group.cancelAll()

                switch result {
                case .loopEnded:
                    return
                case .windowClosed:
                    print("Availability window closed; disconnecting until the next scheduled window.")
                    return
                }
            }
        }
    }

    private func sleepNanoseconds(for interval: TimeInterval) -> UInt64 {
        let seconds = max(1.0, min(interval, Double(UInt64.max) / 1_000_000_000))
        return UInt64(seconds * 1_000_000_000)
    }

    private func runProviderLoopWithFanLease(_ loop: ProviderLoop) async throws {
        try await withFanActivityLease(providerVersion: ProviderCore.version) {
            try await loop.run()
        }
    }

    /// Run `serve` until it returns or the process receives SIGTERM/SIGINT.
    /// launchd delivers SIGTERM on `bootout` (`darkbloom stop`) and on
    /// `kickstart -k` (`darkbloom restart`, the watchdog's recovery, the
    /// auto-update relaunch); a foreground human run gets SIGINT from Ctrl-C.
    /// Without a trap the default action killed the daemon instantly and
    /// every in-flight request became a 502 "provider disconnected" on the
    /// coordinator. The trap cancels the serve task instead, which is
    /// `ProviderLoop.run()`'s refuse → drain → close path; launchd's
    /// `ExitTimeOut` (set by `LaunchAgent` to the drain bound) and a second
    /// signal (see `ShutdownSignalTrap`) remain the hard stops.
    private func runUntilTerminationSignal(
        _ serve: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await serve() }
            group.addTask { await ShutdownSignalTrap.waitForTermination() }
            // Whichever finishes first ends the other: a signal cancels the
            // serve task; a serve exit releases the trap.
            do {
                try await group.next()
            } catch {
                group.cancelAll()
                throw error
            }
            group.cancelAll()
            // Wait for the drain to complete. The trap task's release, and a
            // schedule wait interrupted by the cancellation, surface as
            // CancellationError — not a serve failure.
            while true {
                do {
                    guard try await group.next() != nil else { break }
                } catch is CancellationError {
                    continue
                }
            }
        }
    }

}
