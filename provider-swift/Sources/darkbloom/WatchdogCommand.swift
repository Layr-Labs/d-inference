import Foundation
import ArgumentParser
import ProviderCore

/// `darkbloom watchdog` — one crash-recovery check, then exit. Run every minute
/// by `WatchdogAgent` (launchd StartInterval). Hidden: machine-invoked, not a
/// user verb. The thin I/O shell around `WatchdogPolicy`.
struct Watchdog: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watchdog",
        abstract: "Internal: one provider crash-recovery check (run by launchd).",
        shouldDisplay: false
    )

    @OptionGroup var configOptions: ConfigOptions

    mutating func run() async throws {
        Darkbloom.ensureLogging()

        let now = Date().timeIntervalSince1970
        let enabled = Self.autoRestartEnabled(configPath: configOptions.config)
        let liveness = WatchdogProbe.probeProvider(now: now)
        let state = WatchdogStateStore.read()
        // Ignore a downSince left over from a previous boot (fresh window per outage).
        let bootTime = now - ProcessInfo.processInfo.systemUptime
        let downSince = WatchdogPolicy.effectiveDownSince(state.downSince, bootTime: bootTime)

        let decision = WatchdogPolicy.decide(
            autoRestartEnabled: enabled,
            providerLoaded: liveness.loaded,
            providerRunning: liveness.running,
            downSince: downSince,
            now: now
        )

        let grace = Int(WatchdogPolicy.defaultGraceSeconds)
        switch decision {
        case .restart:
            // kickstartIfLoaded re-checks loaded, so a `stop` racing the probe is a no-op.
            do {
                let restarted = try LaunchAgent.kickstartIfLoaded()
                log(restarted ? "provider down > \(grace)s — restart issued"
                              : "provider no longer loaded — skipping restart")
            } catch {
                log("restart failed: \(error)")
            }
        case .startGrace:
            log("provider appears down — will restart in \(grace)s if it stays down")
        case .waiting(let remaining):
            log("provider still down — restart in ~\(Int(remaining))s")
        case .healthy:
            if downSince != nil { log("provider recovered — cancelling pending restart") }
        case .disabled, .notManaged:
            break
        }

        if let newState = WatchdogPolicy.nextState(for: decision, current: state, now: now),
           !WatchdogStateStore.write(newState) {
            log("warning: could not persist watchdog state (check ~/.darkbloom)")
        }
    }

    /// Read just `auto_restart` cheaply; fail open to enabled so a missing or
    /// malformed config never silently disables recovery.
    static func autoRestartEnabled(configPath: String?) -> Bool {
        let path: URL
        if let configPath {
            path = URL(fileURLWithPath: (configPath as NSString).expandingTildeInPath)
        } else if let resolved = try? ConfigManager.defaultConfigPath() {
            path = resolved
        } else {
            return true
        }
        guard FileManager.default.fileExists(atPath: path.path),
              let config = try? ConfigManager.load(from: path) else { return true }
        return config.provider.autoRestart
    }

    /// launchd routes stdout to ~/.darkbloom/watchdog.log; healthy ticks log nothing.
    private func log(_ message: String) {
        print("[\(ISO8601DateFormatter().string(from: Date()))] watchdog: \(message)")
    }
}
