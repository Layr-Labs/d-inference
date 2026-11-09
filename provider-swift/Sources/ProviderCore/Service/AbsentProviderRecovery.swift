import Foundation

/// Missing-job recovery, including durable candidate retry and rollback. Every state transition and new command
/// is under the shared lifecycle lease. No enable/kickstart/restart fallback.
public enum AbsentProviderRecovery {
    public enum Outcome: Equatable {
        case loaded, deferred, ineligible, startGrace, waiting, issued, unknown
    }
    enum BootstrapResult { case issued, definitelyNotIssued, unknown }
    enum RecoveryError: Error {
        case unrecognizedLaunchdResult, persistenceFailed
    }
    struct Snapshot: Equatable {
        var autoRestart: Bool
        var loaded: Bool
        var running: Bool
        var installed: Bool
        var explicitlyEnabled: Bool
        var eligible: Bool {
            autoRestart && !loaded && !running && installed && explicitlyEnabled
        }
    }
    struct RestartTarget {
        var version: String
        var guardAllowed: Bool
    }
    struct StagedGuard {
        var undo: (() -> Void)?
        var emit: () -> Void
    }

    static func explicitlyEnabled(_ output: String, label: String) -> Bool {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let grammar = #"^disabled services = \{\s*(?:"[^"\r\n]+"\s*=>\s*(?:true|false|enabled|disabled)\s*,?\s*)*\}$"#
        guard trimmed.range(of: grammar, options: .regularExpression) != nil else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: label)
        let pattern = "\\\"" + escaped + "\\\"\\s*=>\\s*(true|false|enabled|disabled)\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let records = regex.matches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed))
        guard records.count == 1, let value = Range(records[0].range(at: 1), in: trimmed) else { return false }
        return trimmed[value] == "false" || trimmed[value] == "enabled"
    }

    /// This is the production mapping seam: the old CLI mapping passed only
    /// snapshot.loaded, losing the distinction between enabled and stopped.
    static func decision(snapshot: Snapshot, state: WatchdogState,
                         now: Double, bootTime: Double) -> WatchdogDecision {
        WatchdogPolicy.decide(
            autoRestartEnabled: snapshot.autoRestart,
            providerLoaded: snapshot.loaded,
            providerRunning: snapshot.running,
            downSince: WatchdogPolicy.effectiveDownSince(state.downSince, bootTime: bootTime),
            now: now)
    }

    /// Pure orchestration seam. No closure is called before lease acquisition;
    /// timer/issued state is read and persisted before that lease is released.
    static func performTick(
        acquire: () throws -> (() -> Void),
        snapshot: () throws -> Snapshot,
        prepare: () throws -> String?,
        readState: () -> WatchdogState,
        writeState: (WatchdogState) -> Bool,
        bootstrap: () throws -> BootstrapResult,
        stageGuard: (Int, Double, String) -> StagedGuard,
        clock: () -> Double,
        bootTime: Double,
        prepareRestart: (String) throws -> RestartTarget? = { RestartTarget(version: $0, guardAllowed: true) }
    ) throws -> Outcome {
        let release = try acquire()
        defer { release() }
        // Refuse deliberately stopped/ineligible services BEFORE journal
        // recovery, which may itself mutate the installed tree. Re-sample after
        // recovery below because it may change the installed release/plist.
        let initialIntent = try snapshot()
        if initialIntent.loaded { return .loaded }
        if !initialIntent.eligible {
            let current = readState()
            let now = clock()
            let choice = decision(snapshot: initialIntent, state: current, now: now, bootTime: bootTime)
            if let next = WatchdogPolicy.nextState(for: choice, current: current, now: now),
               !writeState(next) { throw RecoveryError.persistenceFailed }
            return .ineligible
        }
        // Replay the journal before choosing a version or touching outage state.
        guard let installedVersion = try prepare() else { return .deferred }
        // Recovery may change the installed tree: sample intent/liveness only
        // after that work, still within the same lifecycle lease.
        let intent = try snapshot()
        if intent.loaded { return .loaded }
        let state = readState()
        let now = clock()
        let choice = decision(snapshot: intent, state: state, now: now, bootTime: bootTime)
        switch choice {
        case .restart:
            // Candidate attribution/rollback happens only after outage grace,
            // under this same lease. Backoff never consumes a restart count.
            guard let target = try prepareRestart(installedVersion) else { return .deferred }
            // A rollback may change the install; revalidate stop/liveness intent
            // before staging a guard or registering the service.
            let finalIntent = try snapshot()
            if finalIntent.loaded { return .loaded }
            guard finalIntent.eligible else { return .ineligible }
            let downSince = WatchdogPolicy.effectiveDownSince(state.downSince, bootTime: bootTime)
            let count = WatchdogPolicy.versionScopedCrashLoopCount(
                WatchdogPolicy.crashLoopCount(current: state, effectiveDownSince: downSince),
                recordedVersion: state.lastRestartVersion, installedVersion: target.version)
            var staged: StagedGuard?
            if target.guardAllowed && count >= WatchdogPolicy.crashLoopTripThreshold {
                staged = stageGuard(count, now, target.version)
            }
            var retainGuard = false
            defer { if !retainGuard { staged?.undo?() } }
            let result: BootstrapResult
            do { result = try bootstrap() }
            catch { result = .unknown }
            switch result {
            case .definitelyNotIssued:
                // Only a caller that established nonissuance may undo a guard.
                return .deferred
            case .unknown:
                // Timeout/transport failure may follow successful registration.
                // Keep mitigation but do not invent a restart timestamp/count or
                // emit an issued-restart event. Next tick re-observes launchd.
                retainGuard = true
                return .unknown
            case .issued:
                retainGuard = true
                staged?.emit()
            }
            // Count, version and timestamp all describe this issued bootstrap.
            // Same policy as loaded-job recovery; no new timestamp with stale
            // version/counter metadata and no counter advance on failed issuance.
            if let next = WatchdogPolicy.nextState(for: .restart, current: state,
                    now: clock(), crashLoopCount: count, crashLoopVersion: target.version),
               !writeState(next) { throw RecoveryError.persistenceFailed }
            return .issued
        default:
            if let next = WatchdogPolicy.nextState(for: choice, current: state, now: now),
               !writeState(next) { throw RecoveryError.persistenceFailed }
            switch choice {
            case .startGrace: return .startGrace
            case .waiting: return .waiting
            default: return .ineligible
            }
        }
    }

    /// A missing-service diagnostic must identify the complete target label.
    /// A different service or an arbitrary substring is not proof of absence.
    static func jobIsLoadedResult(status: Int32, stderr: String, label: String) throws -> Bool {
        if status == 0 { return true }
        let missing = "could not find service \"\(label)\"".lowercased()
        let confirmsAbsence = stderr.lowercased().split(whereSeparator: \.isNewline).contains { line in
            let diagnostic = line.trimmingCharacters(in: .whitespaces)
            return diagnostic == missing || diagnostic.hasPrefix(missing + " in domain")
        }
        guard [Int32(3), Int32(113)].contains(status), confirmsAbsence else {
            throw RecoveryError.unrecognizedLaunchdResult
        }
        return false
    }

    // MARK: - Effectful adapter (omit only this section for an explicit leaf fixture)

    /// Internal boundary-only test seam. File stores, update sessions and
    /// journal recovery remain real; production resolves the same live paths.
    struct Paths {
        let plist: URL
        let watchdogState: URL
        let daemonState: URL
        let guardEnvironment: [String: String]

        static var live: Self {
            Self(plist: LaunchAgent.plistPath(), watchdogState: WatchdogStateStore.path(),
                 daemonState: DaemonStateFile.path(), guardEnvironment: ProcessInfo.processInfo.environment)
        }
    }


    /// All newly introduced launchctl operations use the existing bounded runner.
    /// No WatchdogProbe.probeProvider/isLoaded/launchSnapshot calls are hidden in
    /// this adapter: those use unbounded launchctl plumbing.
    static func jobIsLoaded(runner: SecurityCommandRunner) throws -> Bool {
        let printed = try runner.run("/bin/launchctl", ["print", LaunchctlControl.target(label: LaunchAgent.label)])
        return try jobIsLoadedResult(status: printed.terminationStatus,
                                     stderr: printed.stderr, label: LaunchAgent.label)
    }

    static func snapshot(autoRestart: Bool, runner: SecurityCommandRunner, paths: Paths = .live) throws -> Snapshot {
        if try jobIsLoaded(runner: runner) {
            return Snapshot(autoRestart: autoRestart, loaded: true, running: false,
                            installed: false, explicitlyEnabled: false)
        }
        let overrides = try runner.run("/bin/launchctl", ["print-disabled", LaunchctlControl.guiDomain()])
        guard overrides.terminationStatus == 0 else { throw RecoveryError.unrecognizedLaunchdResult }
        // Local process-identity comparison only; this helper starts no process.
        let orphanAlive = DaemonStateFile.read(from: paths.daemonState).map { WatchdogProbe.recordBelongsToLiveProcess($0) } ?? false
        let plist = (try? Data(contentsOf: paths.plist)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        }
        let installed = (plist?["Label"] as? String) == LaunchAgent.label
            && (plist?["RunAtLoad"] as? Bool) == true
        return Snapshot(autoRestart: autoRestart, loaded: false, running: orphanAlive,
                        installed: installed,
                        explicitlyEnabled: explicitlyEnabled(overrides.stdout, label: LaunchAgent.label))
    }

    public static func handleTick(updater: SelfUpdater, autoRestart: () -> Bool) throws -> Outcome {
        try handleTick(updater: updater, autoRestart: autoRestart,
                       runner: .bounded(timeout: 3), paths: .live,
                       clock: { Date().timeIntervalSince1970 },
                       bootTime: Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime)
    }

    static func handleTick(updater: SelfUpdater, autoRestart: () -> Bool,
                           runner: SecurityCommandRunner, paths: Paths,
                           clock: () -> Double, bootTime: Double) throws -> Outcome {
        // Reconcile an uncertain absent-job bootstrap before handing a loaded
        // candidate to the existing health/startup-timeout path. No launch or
        // health is inferred solely from registration.
        if try jobIsLoaded(runner: runner) {
            // Attribution is best-effort here: failure must not disable the
            // existing loaded-job probe/degraded-restart path. No failed probe
            // clears intent; a later tick retries reconciliation.
            try? reconcileLoadedIntent(updater: updater, autoRestart: autoRestart,
                                       runner: runner, clock: clock)
            return .loaded
        }
        var session: SelfUpdater.UpdateSession?
        return try performTick(acquire: {
            let lease = try updater.beginUpdateSession(operation: "watchdog-absent-job", timeout: 0)
            session = lease
            return { lease.release() }
        }, snapshot: {
            try snapshot(autoRestart: autoRestart(), runner: runner, paths: paths)
        }, prepare: {
            guard let session else { return nil }
            try session.recover(now: clock())
            let recovery = try session.readState()
            return recovery.candidate?.release.version ?? SelfUpdater.effectiveInstalledVersion(
                processVersion: updater.currentVersion, recorded: recovery.current?.version)
        }, readState: {
            WatchdogStateStore.read(from: paths.watchdogState)
        }, writeState: {
            WatchdogStateStore.write($0, to: paths.watchdogState)
        }, bootstrap: {
            guard let session else { return .definitelyNotIssued }
            var recovery: UpdateRecoveryState
            do {
                recovery = try session.readState()
                if recovery.candidate != nil {
                    // Absence was revalidated under the lease immediately above.
                    // Persist intent BEFORE the external command. Keep it on an
                    // ambiguous result so loaded-path reconciliation can attribute
                    // observed launch evidence without inventing a failed attempt.
                    guard recovery.prepareLaunchIntent(now: clock(), baseline: nil) else {
                        return .definitelyNotIssued
                    }
                    try session.writeState(recovery)
                }
            } catch {
                // The external command has not run: undo any newly staged
                // guard rather than treating a persistence refusal as issuance.
                return .definitelyNotIssued
            }
            let result = try runner.run("/bin/launchctl",
                ["bootstrap", LaunchctlControl.guiDomain(), paths.plist.path])
            // A nonzero response does not generally prove registration never
            // happened (including a service concurrently registered elsewhere).
            guard result.terminationStatus == 0 else { return .unknown }
            if recovery.markLaunchIssued(now: clock()) {
                try session.writeState(recovery)
            }
            return .issued
        }, stageGuard: { count, now, version in
            let trip = KVBackendCrashLoopGuard.stageTrip(crashCount: count, now: now,
                guardedVersion: version, lastKnownModel: DaemonStateFile.read(from: paths.daemonState)?.currentModel,
                environment: paths.guardEnvironment)
            let undo: (() -> Void)?
            if trip.persisted, let undoTrip = trip.undo {
                undo = { undoTrip() }
            } else {
                undo = nil
            }
            return StagedGuard(undo: undo, emit: { trip.emit() })
        }, clock: clock, bootTime: bootTime, prepareRestart: { _ in
            guard let session else { return nil }
            return try prepareAbsentCandidateRestart(session: session,
                processVersion: updater.currentVersion, now: clock())
        })
    }

    /// Same candidate transition order as loaded-job recovery, without a
    /// network update check. Caller has proved no job or living provider and
    /// owns the lifecycle lease; rollback uses the existing signed store.
    static func prepareAbsentCandidateRestart(session: SelfUpdater.UpdateSession,
                                               processVersion: String, now: Double) throws -> RestartTarget? {
        var recovery = try session.readState()
        let before = recovery
        // No launch observation exists for an absent job. Discard a prepared
        // but unconfirmed intent without charging it; charge confirmed issued
        // attempts exactly once through the durable pendingAttemptID.
        _ = recovery.reconcileLaunchIntent(snapshot: nil, now: now)
        _ = recovery.recordPendingAttemptFailure(now: now)
        if recovery != before { try session.writeState(recovery) }
        guard !recovery.isCandidateRetryBackedOff(now: now) else { return nil }

        var rolledBack = false
        if let candidate = recovery.candidate,
           candidate.failureCount >= UpdateRecoveryState.rollbackThreshold,
           candidate.rollbackBlockedReason == nil {
            do {
                _ = try session.rollback(now: now,
                    reason: "automatic rollback after \(candidate.failureCount) failed starts")
                recovery = try session.readState()
                rolledBack = true
            } catch {
                // A rollback can commit before final cleanup throws. Recover
                // and reload durable truth; never resurrect the stale candidate.
                recovery = try recoverRollbackOutcome(session: session, now: now, reason: "\(error)")
                if recovery.candidate != nil { return nil }
                rolledBack = true
            }
        }
        let candidateOwnsRecovery = recovery.candidate != nil
            && recovery.candidate?.rollbackBlockedReason == nil
        return RestartTarget(
            version: recovery.candidate?.release.version ?? SelfUpdater.effectiveInstalledVersion(
                processVersion: processVersion, recorded: recovery.current?.version),
            guardAllowed: !rolledBack && !candidateOwnsRecovery)
    }

    static func recoverRollbackOutcome(session: SelfUpdater.UpdateSession,
                                       now: Double, reason: String) throws -> UpdateRecoveryState {
        try session.recover(now: now)
        var recovery = try session.readState()
        if recovery.candidate != nil {
            recovery.deferRetryAfterRollbackFailure(now: now, reason: reason)
            try session.writeState(recovery)
        }
        return recovery
    }

    static func reconcileLoadedIntent(updater: SelfUpdater, autoRestart: () -> Bool,
                                      runner: SecurityCommandRunner, clock: () -> Double) throws {
        guard autoRestart() else { return }
        let session: SelfUpdater.UpdateSession
        do {
            session = try updater.beginUpdateSession(operation: "watchdog-absent-intent", timeout: 0)
        } catch {
            // Preserve the existing loaded-job degraded-recovery behavior.
            // This tick cannot mutate attribution without ownership; retry later.
            return
        }
        defer { session.release() }
        // Read before replay: ordinary loaded jobs require no new journal work.
        let initial = try session.readState()
        guard initial.candidate?.launchIntent != nil else { return }
        let overrides = try runner.run("/bin/launchctl", ["print-disabled", LaunchctlControl.guiDomain()])
        guard overrides.terminationStatus == 0,
              explicitlyEnabled(overrides.stdout, label: LaunchAgent.label), autoRestart() else { return }
        try session.recover(now: clock())
        var recovery = try session.readState()
        guard let intent = recovery.candidate?.launchIntent else { return }
        let printed = try runner.run("/bin/launchctl", ["print", LaunchctlControl.target(label: LaunchAgent.label)])
        guard try jobIsLoadedResult(status: printed.terminationStatus,
                                   stderr: printed.stderr, label: LaunchAgent.label) else { return }
        let observed = LaunchAgent.parseLaunchSnapshot(label: LaunchAgent.label, output: printed.stdout)
        // Missing/uncertain launch evidence leaves intent intact. Registration
        // alone is neither an issued attempt nor a healthy candidate.
        if intent.baseline == nil {
            guard (observed.runs ?? 0) > 0 || observed.process != nil else { return }
        }
        guard observed.provesLaunch(after: intent.baseline) else { return }
        if recovery.reconcileLaunchIntent(snapshot: observed, now: clock()) {
            try session.writeState(recovery)
        }
    }

}
