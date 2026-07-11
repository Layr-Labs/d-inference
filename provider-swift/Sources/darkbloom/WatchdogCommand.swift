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
        let settings = Self.settings(configPath: configOptions.config)
        let liveness = WatchdogProbe.probeProvider(now: now)
        let daemonState = DaemonStateFile.read()
        let providerActive = WatchdogProbe.providerActive(
            processRunning: liveness.running,
            daemonState: daemonState,
            now: now
        )
        let state = WatchdogStateStore.read()
        // Ignore a downSince left over from a previous boot (fresh window per outage).
        let bootTime = now - ProcessInfo.processInfo.systemUptime
        let downSince = WatchdogPolicy.effectiveDownSince(state.downSince, bootTime: bootTime)

        let decision = WatchdogPolicy.decide(
            autoRestartEnabled: settings.autoRestart,
            providerLoaded: liveness.loaded,
            providerRunning: providerActive,
            downSince: downSince,
            now: now
        )
        let updater = SelfUpdater(coordinatorBaseURL: settings.coordinatorURL)
        let recovery = WatchdogRecoveryService(
            updater: updater,
            dependencies: .init(
                kickstartIfLoaded: { try LaunchAgent.kickstartIfLoaded() },
                providerStillLoaded: {
                    LaunchAgent.isAnySupportedLabelLoaded()
                },
                log: { Self.log($0) }
            )
        )

        let grace = Int(WatchdogPolicy.defaultGraceSeconds)
        var persistenceDecision = decision
        switch decision {
        case .restart:
            let outcome = await recovery.recoverDownProvider(
                autoUpdateEnabled: settings.autoUpdate,
                now: now
            )
            persistenceDecision = Self.recordRecoveryOutcome(
                outcome,
                grace: grace,
                now: now
            )
        case .startGrace:
            Self.log("provider appears down — will restart in \(grace)s if it stays down")
        case .waiting(let remaining):
            Self.log("provider still down — restart in ~\(Int(remaining))s")
        case .healthy:
            let health = recovery.observeHealthyProvider(
                providerRunning: liveness.running,
                daemonState: daemonState,
                now: now
            )
            if case .inactiveCandidate(let attemptStartedAt) = health {
                Self.log(
                    "new version has no fresh heartbeat \(Int(now - attemptStartedAt))s after launch — treating it as a failed start")
                let outcome = await recovery.recoverDownProvider(
                    autoUpdateEnabled: settings.autoUpdate,
                    now: now
                )
                _ = Self.recordRecoveryOutcome(
                    outcome,
                    grace: grace,
                    now: now
                )
            } else if case .failed(let reason) = health {
                Self.log("candidate health persistence failed: \(reason)")
            }
            if downSince != nil { Self.log("provider recovered — cancelling pending restart") }
        case .disabled, .notManaged:
            break
        }

        if let newState = WatchdogPolicy.nextState(for: persistenceDecision, current: state, now: now),
           !WatchdogStateStore.write(newState) {
            Self.log("warning: could not persist watchdog state (check ~/.darkbloom)")
        }
    }

    struct Settings: Equatable {
        let autoRestart: Bool
        let autoUpdate: Bool
        let coordinatorURL: String
    }

    static func settings(configPath: String?) -> Settings {
        if let configPath {
            let path = URL(fileURLWithPath: (configPath as NSString).expandingTildeInPath)
            let config = (try? ConfigManager.load(from: path))
                ?? ProviderConfig(provider: ProviderSettings(name: "darkbloom"))
            return Settings(
                autoRestart: config.provider.autoRestart,
                autoUpdate: config.provider.autoUpdate,
                coordinatorURL: config.coordinator.url
            )
        }
        let config = ConfigManager.loadDefault()
        return Settings(
            autoRestart: config.provider.autoRestart,
            autoUpdate: config.provider.autoUpdate,
            coordinatorURL: config.coordinator.url
        )
    }

    /// Read just `auto_restart` cheaply; fail open to enabled so a missing or
    /// malformed config never silently disables recovery.
    static func autoRestartEnabled(configPath: String?) -> Bool {
        settings(configPath: configPath).autoRestart
    }

    private static func recordRecoveryOutcome(
        _ outcome: WatchdogRecoveryService.DownOutcome,
        grace: Int,
        now: Double
    ) -> WatchdogDecision {
        switch outcome {
        case .restartIssued(let updatedTo, let rolledBackTo):
            var details: [String] = []
            if let updatedTo { details.append("updated to v\(updatedTo)") }
            if let rolledBackTo { details.append("rolled back to v\(rolledBackTo)") }
            let suffix = details.isEmpty ? "" : " (\(details.joined(separator: ", ")))"
            log("provider down > \(grace)s — restart issued\(suffix)")
            return .restart
        case .noLongerLoaded:
            log("provider no longer loaded — skipping restart")
            return .restart
        case .retryBackoff(let until, let reason):
            log(
                "restart deferred for rollback safety until \(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: until))): \(reason)")
            return .waiting(remaining: max(0, until - now))
        case .lockBusy(let reason):
            log("restart deferred while another update operation finishes: \(reason)")
            return .waiting(remaining: 0)
        case .failed(let reason):
            log("restart recovery failed: \(reason)")
            return .waiting(remaining: 0)
        }
    }

    /// launchd routes stdout to ~/.darkbloom/watchdog.log; healthy ticks log nothing.
    private static func log(_ message: String) {
        print("[\(ISO8601DateFormatter().string(from: Date()))] watchdog: \(message)")
    }
}
