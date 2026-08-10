import Foundation
import ArgumentParser
import ProviderCore

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show local provider configuration and hardware status."
    )

    @OptionGroup var configOptions: ConfigOptions

    mutating func run() async throws {
        // Best-effort: tell the user if a newer release is published before
        // we dump current status. Bounded by a 2s timeout in UpdateBanner.
        await runUpdateBannerIfEnabled()

        let snapshot = try loadRuntimeSnapshot(configOptions: configOptions)
        let config = snapshot.config
        let models = advertisedModels(from: snapshot.models, config: config)

        print("darkbloom \(ProviderCore.version)")
        print("Provider: \(config.provider.name)")
        print("Config: \(describeConfigPath(snapshot))")
        print("Coordinator: \(config.coordinator.url)")
        print("Backend port: \(config.backend.port)")
        print("Configured model: \(config.backend.model ?? "auto-select")")
        print("Idle timeout: \(config.backend.idleTimeoutMins == 0 ? "disabled" : "\(config.backend.idleTimeoutMins)m")")
        let enabledBeta = BetaFeatures.enabledIDs(in: config)
        print("Beta features: \(enabledBeta.isEmpty ? "none" : enabledBeta.joined(separator: ", ")) (manage with `darkbloom beta`)")
        print("Auto-restart: \(autoRestartStatus(config: config))")

        if let hardware = snapshot.hardware {
            print("Hardware: \(hardware.chipName), \(Status.memoryDescription(totalGb: hardware.memoryGb, limitGB: config.provider.memoryLimitGB)) RAM, \(hardware.gpuCores) GPU cores")
            print("Inference memory: \(Status.inferenceMemoryGb(availableGb: hardware.memoryAvailableGb, provider: config.provider)) GB available")
        } else {
            print("Hardware: unavailable (\(snapshot.hardwareError?.localizedDescription ?? "unknown error"))")
        }

        print(bootSecurityStatusLine(BootSecuritySnapshot.live()))

        if let scheduleConfig = config.schedule,
           let schedule = Schedule.from(config: scheduleConfig) {
            let active = schedule.isActiveNow()
            print("Schedule: \(schedule.describe())")
            print("Availability: \(active ? "active" : "inactive")")
        } else {
            print("Schedule: always available")
        }

        let enabledFilter = config.backend.enabledModels.isEmpty ? "none" : config.backend.enabledModels.joined(separator: ", ")
        print("Enabled model filter: \(enabledFilter)")
        print("Local MLX models: \(models.count)")

        // Live daemon state (from the state file the running daemon writes).
        print("")
        printDaemonStatus(config: config)

        // Crash-loop KV-backend guard — printed whether or not the daemon is
        // up, because the guard's whole story happens while the daemon is
        // crashing: an operator asking "why is this box on contiguous?" (or
        // "why was it down for 20 minutes?") gets the answer here.
        for line in KVBackendGuardDiagnostics.statusLines(
            record: KVBackendGuardStore.read(),
            now: Date().timeIntervalSince1970,
            runningVersion: ProviderCore.version)
        {
            print(line)
        }
    }

    /// One-line summary of crash-recovery state: the config opt-out plus whether
    /// the launchd watchdog agent is actually armed.
    private func autoRestartStatus(config: ProviderConfig) -> String {
        guard config.provider.autoRestart else {
            return "off (auto_restart = false)"
        }
        if WatchdogAgent.isLoaded() {
            return "on (watchdog active; relaunches ~5 min after a crash)"
        }
        if WatchdogAgent.isInstalled() {
            return "on (watchdog installed but not loaded)"
        }
        return "on (watchdog not installed — run `darkbloom start` or `restart` to arm)"
    }

    func bootSecurityStatusLine(_ bootSecurity: BootSecuritySnapshot) -> String {
        let status = bootSecurity.issues.isEmpty ? CheckStatus.pass : .warn
        return "Local boot checks: \(status.marker) \(bootSecurity.macOSSummary); "
            + "SIP \(bootSecurity.sip.summary); Secure Boot has no local public check"
    }

    /// Total-memory rendering with the operator cap appended when one is in
    /// effect: "256 GB (limit: 150 GB)". Mirrors MemoryLimit normalization —
    /// 0 or a value at/above physical means "no limit" and is not shown.
    static func memoryDescription(totalGb: UInt64, limitGB: UInt64?) -> String {
        guard let limitGB, limitGB > 0, limitGB < totalGb else { return "\(totalGb) GB" }
        return "\(totalGb) GB (limit: \(limitGB) GB)"
    }

    /// The "Inference memory" figure: the hardware-derived available number,
    /// clamped to the effective cap when an operator limit is in force — a
    /// 256 GB Mac limited to 150 GB must not print "252 GB available" one
    /// line under "limit: 150 GB". Uncapped boxes keep the historical
    /// hardware-derived figure (the 90% cap is a serving budget, not an
    /// availability claim, and changing that line is out of scope here).
    static func inferenceMemoryGb(
        availableGb: UInt64,
        provider: ProviderSettings,
        physicalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> UInt64 {
        guard provider.memoryLimitBytes(physicalBytes: physicalBytes) != nil else {
            return availableGb
        }
        let capGb = provider.effectiveCapBytes(physicalBytes: physicalBytes) / 1_073_741_824
        return min(availableGb, capGb)
    }

    /// Prints the running daemon's live state, including the coordinator's last
    /// trust reason — the answer to "am I earning, and if not, why?".
    private func printDaemonStatus(config: ProviderConfig) {
        let now = Date().timeIntervalSince1970
        guard let state = DaemonStateFile.read() else {
            print("Daemon: not running (run `darkbloom start`)")
            return
        }
        let alive = daemonProcessAlive(pid: state.pid)
        if !alive {
            print("Daemon: not running (stale state file)")
            return
        }
        print(daemonHealthLine(
            state: state,
            now: now,
            heartbeatIntervalSecs: config.coordinator.heartbeatIntervalSecs))

        if let trust = state.trust {
            let advice = TrustReasonCatalog.advice(level: trust.trustLevel, status: trust.status, reason: trust.reason)
            print("Trust: \(trust.trustLevel) / \(trust.status)")
            print("  → \(advice.message)")
            if let fix = advice.fix { print("  → fix: \(fix)") }
        } else {
            print("Trust: awaiting coordinator status")
        }

        print("Warm models: \(WarmModelsFormat.warmModelsLine(warmModels: state.warmModels, currentModel: state.currentModel))")
        print("\(WarmModelsFormat.mostRecentlyUsedLabel): \(WarmModelsFormat.mostRecentlyUsedLine(currentModel: state.currentModel))")
        print("Requests served: \(state.stats.requestsServed)  |  tokens: \(state.stats.tokensGenerated)")
        if let err = state.lastModelLoadError {
            print("Last model-load error: \(err.model): \(err.message)")
        }

        // Which KV backend is this box actually serving on, and is MTP
        // producing drafts or merely enabled? Both read the same state file
        // as everything above, against the same `staleAfter` bar, so the block
        // carries its own age — see `KVBackendPosture` for why a bare value
        // would be worse than none.
        for line in KVBackendPosture.statusLines(
            state: state,
            now: now,
            heartbeatIntervalSecs: config.coordinator.heartbeatIntervalSecs)
        {
            print(line)
        }
    }

    /// Both bars come from `KVBackendPosture`, the same source the
    /// slot-posture block reads. `DaemonState.isStale` defaults to a flat
    /// 90 s while that block derives its bound from `heartbeat_interval_secs`,
    /// so at the default 5 s heartbeat — 90 s against 10 s — a 30-second-old
    /// snapshot printed "Daemon: running" immediately above "Slot posture:
    /// STALE": two verdicts on one file, fourteen lines apart, and nothing
    /// to say which to believe.
    ///
    /// THREE states, because one derived bar is still one bar too few.
    /// "The snapshot is suspect" and "the daemon is stuck" are different
    /// claims. `staleAfterSeconds` is four missed writes — 10 s at the
    /// default heartbeat — which transient load crosses on a perfectly
    /// healthy box, so it may only discount the live fields below it.
    /// Only `wedgedAfterSeconds`, eight missed writes floored at 90 s, is
    /// an accusation against the daemon, and it is the same bar `doctor`
    /// withholds its backend verdict at.
    ///
    /// `WatchdogProbe`, `WatchdogRecoveryService` and `DoctorRunner` still
    /// take the flat 90 s default; moving them is a behavior change to
    /// restart and health-gating logic and needs its own review.
    func daemonHealthLine(
        state: DaemonState,
        now: Double,
        heartbeatIntervalSecs: UInt64
    ) -> String {
        let age = state.ageSeconds(now: now)
        let ageText = "\(Int(age.rounded()))s"
        let wedgedAfter = KVBackendPosture.wedgedAfterSeconds(
            heartbeatIntervalSecs: heartbeatIntervalSecs)
        if age > wedgedAfter {
            return "Daemon: running (pid \(state.pid)) but last update \(ageText) ago "
                + "(expected within \(Int(wedgedAfter))s) — possibly wedged"
        }

        let uptime = formatUptime(state.uptimeSeconds(now: now))
        let staleAfter = KVBackendPosture.staleAfterSeconds(
            heartbeatIntervalSecs: heartbeatIntervalSecs)
        guard age > staleAfter else {
            return "Daemon: running (pid \(state.pid), up \(uptime))"
        }
        let period = KVBackendPosture.refreshPeriodSeconds(
            heartbeatIntervalSecs: heartbeatIntervalSecs)
        return "Daemon: running (pid \(state.pid), up \(uptime)) but last update \(ageText) ago "
            + "(expected every ~\(Int(period))s) — snapshot stale, the fields below may be "
            + "out of date"
    }

    private func formatUptime(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h\((s % 3600) / 60)m"
    }
}
