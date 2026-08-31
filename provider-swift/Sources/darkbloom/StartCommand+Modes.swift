// Start serving modes: --local standalone, launchd-foreground (coordinator +
// optional unified local endpoint), and scheduled windows.
import Foundation
import ArgumentParser
import ProviderCore
#if canImport(Darwin)
import Darwin
#endif

extension Start {
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
                modelOverrides: model)
        } else if all {
            selectedModels = snapshot.models
        } else {
            selectedModels = advertisedModels(
                from: snapshot.models,
                config: config)
        }

        guard !selectedModels.isEmpty else {
            printError("No models selected.")
            throw ExitCode.failure
        }

        let (models, modelHashes, modelHashFingerprints) = attachWeightHashes(to: selectedModels)
        let runtimeHashes = (try? RuntimeHashReporter().report().coordinatorRuntimeHashes)
        let authToken = AuthTokenStore.load()
        if let identity = ProcessIdentity.current() {
            try? SelfUpdater(
                coordinatorBaseURL: coordinatorURL
            ).confirmRunningCandidateLaunch(
                processStartedAt: Double(identity.startTimeMicros) / 1_000_000
            )
        }


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
            runtimeCapabilities: runtimeCapabilities,
            modelHashes: modelHashes,
            modelHashFingerprints: modelHashFingerprints
        )

        do {
            if let schedule {
                try await runScheduled(loopConfig: loopConfig, schedule: schedule)
            } else {
                let loop = try ProviderLoop(config: loopConfig)
                try await runProviderLoopWithFanLease(loop)
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

}
