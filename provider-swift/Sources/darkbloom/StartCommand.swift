import Foundation
import ArgumentParser
import ProviderCore

struct Start: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start the provider as a background service.",
        discussion: """
        Scans local MLX models, lets you pick which to serve, then launches
        a launchd background service. Use --model to skip the interactive picker.
        """
    )

    @OptionGroup var configOptions: ConfigOptions

    @Option(help: "Override coordinator WebSocket URL.")
    var coordinatorURL: String?

    @Option(help: "Model ID to serve (repeatable, skips interactive picker).")
    var model: [String] = []

    @Flag(help: "Serve all local models (skips interactive picker).")
    var all = false

    @Option(help: "Idle timeout in minutes before unloading the model.")
    var idleTimeout: UInt64?

    @Flag(inversion: .prefixedNo, help: .hidden)
    var foreground = false

    @Flag(help: "Run a local OpenAI-compatible HTTP server only; do not connect to the coordinator.")
    var local = false

    @Option(help: "Local server port (used with --local).")
    var port: UInt16 = 8000

    mutating func run() async throws {
        // GPU is required. Reject CPU fallback up-front so we never
        // come up reporting healthy and then silently churn at 0.5 tok/s.
        do {
            _ = try GPUEnforcement.requireMetal()
        } catch {
            printError("\(error)")
            throw ExitCode.failure
        }

        let snapshot = try loadRuntimeSnapshot(configOptions: configOptions)
        let effectiveCoordinator = coordinatorURL ?? snapshot.config.coordinator.url
        var effectiveConfig = snapshot.config
        if let idleTimeout {
            effectiveConfig.backend.idleTimeoutMins = idleTimeout
        }

        guard let hardware = snapshot.hardware else {
            printError("Cannot start: hardware detection failed (\(snapshot.hardwareError?.localizedDescription ?? "unknown"))")
            throw ExitCode.failure
        }

        guard !snapshot.models.isEmpty else {
            printError("No local MLX models found. Download models to ~/.cache/huggingface/hub/")
            throw ExitCode.failure
        }

        if local {
            try await runLocalStandalone(
                snapshot: snapshot,
                config: effectiveConfig,
                hardware: hardware
            )
        } else if foreground {
            try await runForeground(
                snapshot: snapshot,
                hardware: hardware,
                config: effectiveConfig,
                coordinatorURL: effectiveCoordinator
            )
        } else {
            try launchDaemon(
                snapshot: snapshot,
                config: effectiveConfig,
                coordinatorURL: effectiveCoordinator
            )
        }
    }

    // MARK: - Standalone (--local)

    private func runLocalStandalone(
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

        print("darkbloom \(ProviderCore.version) (standalone)")
        print("Listening on 127.0.0.1:\(port)")
        print("Models: \(advertised.count)")
        for m in advertised {
            print("  \(m.id) (\(String(format: "%.1f", m.estimatedMemoryGb)) GB)")
        }
        print("OpenAI-compatible: GET /health, GET /v1/models, POST /v1/chat/completions")
        print()

        // Standalone mode still benefits from the PID lock + sleep prevention.
        try ProcessLifecycle.acquireSingleInstanceLock()
        ProcessLifecycle.preventSystemSleep()
        defer { ProcessLifecycle.releaseSingleInstanceLock() }

        let server = StandaloneServer(
            config: StandaloneServerConfig(
                port: port,
                host: "127.0.0.1",
                maxCachedModels: Int(clamping: config.backend.maxModelSlots)
            ),
            models: advertised
        )
        try await server.start()

        // Wait forever (until SIGINT). In standalone mode we don't have a
        // coordinator event stream to drive the loop, so we just block.
        let waitForever = AsyncStream<Never> { _ in }
        for await _ in waitForever {}
    }

    // MARK: - Foreground (invoked by launchd)

    private func runForeground(
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

        let (models, modelHashes) = attachWeightHashes(to: selectedModels)
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

        let schedule = config.schedule.flatMap { Schedule.from(config: $0) }

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

        let loopConfig = ProviderLoopConfig(
            coordinatorURL: coordinatorURL,
            hardware: hardware,
            models: models,
            config: config,
            authToken: authToken,
            runtimeHashes: runtimeHashes,
            modelHashes: modelHashes
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

    // MARK: - Daemon (interactive picker → launchd)

    private func launchDaemon(
        snapshot: RuntimeSnapshot,
        config: ProviderConfig,
        coordinatorURL: String
    ) throws {
        let selectedModelIDs: [String]

        if !model.isEmpty {
            selectedModelIDs = model
        } else if all {
            selectedModelIDs = snapshot.models.map(\.id)
        } else {
            selectedModelIDs = try interactiveModelPicker(snapshot: snapshot, config: config)
        }

        guard !selectedModelIDs.isEmpty else {
            printError("No models selected.")
            throw ExitCode.failure
        }

        try LaunchAgent.installAndStart(
            coordinatorURL: coordinatorURL,
            models: selectedModelIDs,
            idleTimeout: idleTimeout ?? (config.backend.idleTimeoutMins > 0 ? config.backend.idleTimeoutMins : nil)
        )

        let logPath = LaunchAgent.logPath().path
        print("Provider started as background service.")
        print("  Models:  \(selectedModelIDs.count)")
        for id in selectedModelIDs {
            print("    \(id)")
        }
        print("  Logs:    \(logPath)")
        print()
        print("  darkbloom stop    Stop the provider")
        print("  darkbloom status  Check status")
    }

    // MARK: - Interactive Picker

    private func interactiveModelPicker(
        snapshot: RuntimeSnapshot,
        config: ProviderConfig
    ) throws -> [String] {
        let models = snapshot.models.sorted { $0.id < $1.id }

        print()
        print("  Available models:")
        print()
        for (i, m) in models.enumerated() {
            let sizeStr = String(format: "%.1f GB", m.estimatedMemoryGb)
            let quant = m.quantization ?? ""
            print("    [\(i + 1)] \(m.id)  (\(sizeStr)\(quant.isEmpty ? "" : ", \(quant)"))")
        }
        print()
        print("  Select models (comma-separated numbers, or 'all'): ", terminator: "")

        guard let input = readLine()?.trimmingCharacters(in: .whitespaces), !input.isEmpty else {
            return []
        }

        if input.lowercased() == "all" {
            return models.map(\.id)
        }

        let indices = input.split(separator: ",").compactMap { token -> Int? in
            guard let n = Int(token.trimmingCharacters(in: .whitespaces)) else { return nil }
            return n
        }

        var selected: [String] = []
        for idx in indices {
            guard idx >= 1, idx <= models.count else {
                printError("Invalid selection: \(idx) (must be 1-\(models.count))")
                throw ExitCode.failure
            }
            selected.append(models[idx - 1].id)
        }
        return selected
    }
}
