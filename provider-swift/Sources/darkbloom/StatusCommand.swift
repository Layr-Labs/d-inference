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
        print("Continuous batching: \(config.backend.continuousBatching ? "enabled" : "disabled")")
        print("Idle timeout: \(config.backend.idleTimeoutMins == 0 ? "disabled" : "\(config.backend.idleTimeoutMins)m")")
        print("Auto-restart: \(autoRestartStatus(config: config))")

        if let hardware = snapshot.hardware {
            print("Hardware: \(hardware.chipName), \(hardware.memoryGb) GB RAM, \(hardware.gpuCores) GPU cores")
            print("Inference memory: \(hardware.memoryAvailableGb) GB available")
        } else {
            print("Hardware: unavailable (\(snapshot.hardwareError?.localizedDescription ?? "unknown error"))")
        }

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
        printDaemonStatus()
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

    /// Prints the running daemon's live state, including the coordinator's last
    /// trust reason — the answer to "am I earning, and if not, why?".
    private func printDaemonStatus() {
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
        if state.isStale(now: now) {
            print("Daemon: running (pid \(state.pid)) but last update \(Int(state.ageSeconds(now: now)))s ago — possibly wedged")
        } else {
            print("Daemon: running (pid \(state.pid), up \(formatUptime(state.uptimeSeconds(now: now))))")
        }

        if let trust = state.trust {
            let advice = TrustReasonCatalog.advice(level: trust.trustLevel, status: trust.status, reason: trust.reason)
            print("Trust: \(trust.trustLevel) / \(trust.status)")
            print("  → \(advice.message)")
            if let fix = advice.fix { print("  → fix: \(fix)") }
        } else {
            print("Trust: awaiting coordinator status")
        }

        print("Current model: \(state.currentModel ?? "none loaded")")
        print("Requests served: \(state.stats.requestsServed)  |  tokens: \(state.stats.tokensGenerated)")
        if let err = state.lastModelLoadError {
            print("Last model-load error: \(err.model): \(err.message)")
        }
    }

    private func formatUptime(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h\((s % 3600) / 60)m"
    }
}
