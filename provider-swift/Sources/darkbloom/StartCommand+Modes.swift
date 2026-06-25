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
        hardware: HardwareInfo
    ) async throws {
        let advertised = advertisedModels(
            from: snapshot.models,
            config: config,
            modelOverrides: model,
            includeDisabled: all
        )

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

        // Standalone mode still benefits from the PID lock + sleep prevention.
        try ProcessLifecycle.acquireSingleInstanceLock()
        ProcessLifecycle.preventSystemSleep()
        defer { ProcessLifecycle.releaseSingleInstanceLock() }

        let server = StandaloneServer(
            config: StandaloneServerConfig(
                port: port,
                host: bind,
                maxCachedModels: Int(clamping: config.backend.maxModelSlots),
                authToken: token,
                kvQuant: config.backend.kvQuant,
                adaptivePrefill: config.backend.adaptivePrefill
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

        // Wait forever (until SIGINT). In standalone mode we don't have a
        // coordinator event stream to drive the loop, so we just block.
        let waitForever = AsyncStream<Never> { _ in }
        for await _ in waitForever {}
    }


    // MARK: - Foreground (invoked by launchd)

    internal func runForeground(
        snapshot: RuntimeSnapshot,
        hardware: HardwareInfo,
        config: ProviderConfig,
        coordinatorURL: String
    ) async throws {
        let selectedModels: [ModelInfo]
        if !model.isEmpty {
            selectedModels = advertisedModels(from: snapshot.models, config: config, modelOverrides: model)
        } else if all {
            selectedModels = snapshot.models
        } else {
            selectedModels = advertisedModels(from: snapshot.models, config: config)
        }

        guard !selectedModels.isEmpty else {
            printError("No models selected.")
            throw ExitCode.failure
        }

        let (models, modelHashes, modelHashFingerprints) = attachWeightHashes(to: selectedModels)
        let runtimeHashes = (try? RuntimeHashReporter().report().coordinatorRuntimeHashes)
        let authToken = AuthTokenStore.load()

        if config.provider.autoUpdate {
            try await runStartupAutoUpdate(coordinatorURL: coordinatorURL)
        }

        // ----- Process-level lifecycle: PID lock + caffeinate. -----
        try ProcessLifecycle.acquireSingleInstanceLock()
        ProcessLifecycle.preventSystemSleep()
        defer { ProcessLifecycle.releaseSingleInstanceLock() }

        // Install panic hook BEFORE telemetry so a crash during telemetry
        // setup is itself captured.
        PanicHook.install()

        // Arm crash recovery for the running daemon however it was launched
        // (manual start, login, or auto-update relaunch). Idempotent (skip when
        // already loaded → no churn on restarts) + best-effort.
        if config.provider.autoRestart, !WatchdogAgent.isLoaded() {
            try? WatchdogAgent.installAndStart()
        }

        // ----- Telemetry: configure now so reconnect/inference/panic events flow. -----
        TelemetryClient.shared.configure(TelemetryClientConfig(
            coordinatorURL: coordinatorURL,
            source: .provider,
            authToken: authToken,
            version: ProviderCore.version,
            machineId: macHardwareSerialNumber() ?? ""
        ))

        TelemetryClient.shared.emit(
            kind: .log,
            severity: .info,
            message: "provider starting",
            fields: [
                "backend": .string("mlx-swift"),
                "models": .int(models.count),
            ]
        )

        let schedule: Schedule? = config.schedule.flatMap { Schedule.from(config: $0) }

        print("darkbloom \(ProviderCore.version)")
        print("Backend: mlx-swift")
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
            modelHashes: modelHashes,
            modelHashFingerprints: modelHashFingerprints,
            localEndpoint: localEndpointConfig
        )

        do {
            if let schedule {
                try await runScheduled(loopConfig: loopConfig, schedule: schedule)
            } else {
                let loop = try ProviderLoop(config: loopConfig)
                try await loop.run()
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
        let updater = SelfUpdater(coordinatorBaseURL: coordinatorURL)
        switch await updater.update() {
        case .alreadyUpToDate:
            return
        case .updated(let from, let to):
            print("Updated provider: v\(from) -> v\(to). Restarting into new binary...")
            try ProcessLifecycle.execCurrentProcess()
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
        schedule: Schedule
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
            try await withThrowingTaskGroup(of: ScheduledLoopResult.self) { group in
                group.addTask {
                    try await loop.run()
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

}
