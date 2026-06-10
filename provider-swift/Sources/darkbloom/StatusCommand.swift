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

    /// Prints the running daemon's live state, including the coordinator's last
    /// trust reason — the answer to "am I earning, and if not, why?".
    private func printDaemonStatus() {
        let now = Date().timeIntervalSince1970
        let state = DaemonStateFile.read()
        let stateAlive = state.map { daemonProcessAlive(pid: $0.pid) } ?? false

        // The state file alone can't answer "is the daemon running?": it can be
        // left over from a previous session, or the daemon may be unable to
        // write it at all (e.g. ~/.darkbloom permissions). launchd is the
        // source of truth for the process it manages, so cross-check it before
        // declaring the daemon down.
        let livePID: Int32? = stateAlive ? state?.pid : LaunchAgent.runningPID()

        guard let pid = livePID else {
            if let state {
                // Leftover state file from a previous daemon session (stop,
                // crash, or reboot). Point at the fix, not the artifact.
                print("Daemon: not running (last session ended ~\(formatUptime(state.ageSeconds(now: now))) ago — run `darkbloom start`)")
            } else {
                print("Daemon: not running (run `darkbloom start`)")
            }
            return
        }

        guard let state, state.pid == pid else {
            // launchd says the daemon is up, but the state file is missing or
            // belongs to an older process — live diagnostics are unavailable.
            print("Daemon: running (pid \(pid), managed by launchd)")
            print("  → no live diagnostics: the daemon's state file is missing or from an older session.")
            print("  → if this persists for >1 min, check that ~/.darkbloom is writable, or run `darkbloom stop && darkbloom start`.")
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
