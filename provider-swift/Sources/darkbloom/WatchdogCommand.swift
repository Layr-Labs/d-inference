import Foundation
import ArgumentParser
import ProviderCore

/// Persistent launchd watchdog. Cadence is owned by a monotonic in-process
/// scheduler because GUI-domain StartInterval jobs can become permanently
/// stranded in launchd's on-demand-only mode.
struct Watchdog: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watchdog",
        abstract: "Internal: persistent provider recovery watchdog.",
        shouldDisplay: false
    )

    @OptionGroup var configOptions: ConfigOptions

    mutating func run() async throws {
        Darkbloom.ensureLogging()
        let configPath = configOptions.config
        let scheduler = Task {
            await WatchdogScheduler(
                interval: .seconds(WatchdogAgent.checkIntervalSeconds)
            ).run {
                await Self.runTick(configPath: configPath)
            }
        }
        await WatchdogSignalTrap.waitForTermination()
        scheduler.cancel()
        await scheduler.value
    }

    /// Safe-point tick budget. Larger than the bounded URLSession's
    /// whole-transfer timeout so a normal (slow) download completes; a tick
    /// that exceeds it skips further network work at the next safe point and
    /// proceeds straight to the restart action. Never interrupts a journaled
    /// commit mid-flight.
    static let tickDeadlineSeconds: Double =
        SelfUpdater.watchdogResourceTimeoutSeconds + 120

    static func runTick(configPath: String?) async {
        let now = Date().timeIntervalSince1970
        let tickDeadline = ContinuousClock.now
            + .seconds(Int64(Self.tickDeadlineSeconds))
        let settings = Self.settings(configPath: configPath)
        let liveness = WatchdogProbe.probeProvider(now: now)
        let daemonState = DaemonStateFile.read()
        let providerActive = WatchdogProbe.providerActive(
            processRunning: liveness.running,
            daemonState: daemonState,
            now: now
        )
        // Only trust the daemon-state PID when its live kernel start time still
        // matches what the daemon recorded; a reused PID (e.g. a manual
        // `darkbloom update` holding the lock) falls back to the launchd
        // snapshot so the watchdog never force-kills an unrelated live process.
        let providerIdentity = WatchdogProbe.providerIdentity(
            daemonState: daemonState,
            launchSnapshotProcess: LaunchAgent.launchSnapshot()?.process
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
        let updater = SelfUpdater(
            coordinatorBaseURL: settings.coordinatorURL,
            releaseChannel: settings.releaseChannel,
            urlSession: SelfUpdater.watchdogURLSession()
        )
        let recovery = WatchdogRecoveryService(
            updater: updater,
            dependencies: .init(
                kickstartIfLoaded: { try LaunchAgent.kickstartIfLoaded() },
                providerStillLoaded: {
                    LaunchAgent.isAnySupportedLabelLoaded()
                },
                terminateStaleLockOwner: { owner in
                    guard owner.processIdentity == providerIdentity,
                          let identity = owner.processIdentity
                    else {
                        return false
                    }
                    return ProcessLifecycle.terminate(identity)
                },
                isPastTickDeadline: { ContinuousClock.now > tickDeadline },
                log: { Self.log($0) }
            ),
            candidateStartupTimeoutSeconds: settings.candidateStartupTimeoutSeconds
        )

        let grace = Int(WatchdogPolicy.defaultGraceSeconds)
        var persistenceDecision = decision
        switch decision {
        case .restart:
            let outcome = await recovery.recoverDownProvider(
                autoUpdateEnabled: settings.autoUpdate,
                inactiveProviderIdentity: providerIdentity,
                providerProcessAlive: liveness.running,
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
            switch health {
            case .inactiveCandidate(let attemptStartedAt):
                Self.log(
                    "new version has no fresh heartbeat \(Int(now - attemptStartedAt))s after launch — treating it as a failed start")
                // The candidate is already past its startup window here (that is
                // exactly what .inactiveCandidate means), so the process-alive
                // grace below is a no-op; passed for call-site consistency.
                let outcome = await recovery.recoverDownProvider(
                    autoUpdateEnabled: settings.autoUpdate,
                    inactiveProviderIdentity: providerIdentity,
                    providerProcessAlive: liveness.running,
                    now: now
                )
                _ = Self.recordRecoveryOutcome(
                    outcome,
                    grace: grace,
                    now: now
                )
            case .blockedCandidateRetry(let reason):
                Self.log(
                    "blocked-rollback candidate's retry backoff expired with no heartbeat — retrying restart/rollback (\(reason))")
                let outcome = await recovery.recoverDownProvider(
                    autoUpdateEnabled: settings.autoUpdate,
                    inactiveProviderIdentity: providerIdentity,
                    providerProcessAlive: liveness.running,
                    now: now
                )
                _ = Self.recordRecoveryOutcome(
                    outcome,
                    grace: grace,
                    now: now
                )
            case .failed(let reason):
                Self.log("candidate health persistence failed: \(reason)")
            case .noCandidate, .stabilizing, .promoted, .lockBusy:
                break
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
        let releaseChannel: ProviderReleaseChannel
        /// Derived from the operator's `startup_preload_timeout_secs` so a
        /// raised preload window never reads as a hung candidate launch.
        let candidateStartupTimeoutSeconds: Double
    }

    static func settings(
        configPath: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Settings {
        let config: ProviderConfig
        if let configPath {
            let path = URL(fileURLWithPath: (configPath as NSString).expandingTildeInPath)
            config = (try? ConfigManager.load(from: path))
                ?? ProviderConfig(provider: ProviderSettings(name: "darkbloom"))
        } else {
            config = ConfigManager.loadDefault()
        }
        return Settings(
            autoRestart: config.provider.autoRestart,
            autoUpdate: config.provider.autoUpdate
                && environment["DARKBLOOM_NO_UPDATE_CHECK"] == nil,
            coordinatorURL: config.coordinator.url,
            releaseChannel: config.provider.releaseChannel,
            candidateStartupTimeoutSeconds:
                WatchdogRecoveryService.candidateStartupTimeout(
                    preloadTimeoutSecs: config.backend.startupPreloadTimeoutSecs
                )
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
