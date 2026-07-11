import Foundation

/// Recovery authority driven by the persistent watchdog process's ticks.
/// Update, predecessor rollback, failure attribution, and launch attempt
/// persistence all execute while the same cross-process update lease is held.
///
/// KNOWN LIMITATIONS (see threat model T-043): the watchdog runs the SAME
/// replaceable `darkbloom` binary it protects, so rollback protection depends
/// on the pre-update watchdog process staying alive through a candidate's
/// stabilization window. Rollback does NOT survive a reboot into a candidate
/// whose binary cannot start at all (launchd relaunches the broken candidate
/// as the watchdog too). Quarantine is intentionally single-slot and
/// exact-version: quarantining v3 after v2 overwrites the v2 record, and only
/// normal monotonic version ordering keeps v2 from reinstalling.
public struct WatchdogRecoveryService: Sendable {
    public struct Dependencies: Sendable {
        public var kickstartIfLoaded: @Sendable () throws -> Bool
        public var launchSnapshot: @Sendable () -> ProviderLaunchSnapshot?
        public var providerStillLoaded: @Sendable () -> Bool
        public var processAlive: @Sendable (Int32) -> Bool
        public var terminateStaleLockOwner:
            @Sendable (UpdateProcessLock.Owner) -> Bool
        /// Safe-point tick budget check. Consulted ONLY between complete
        /// operations (never mid-journal, mid-rename, or mid-commit), so an
        /// exceeded budget can defer work but can never corrupt an in-flight
        /// journaled transaction.
        public var isPastTickDeadline: @Sendable () -> Bool
        public var log: @Sendable (String) -> Void

        public init(
            kickstartIfLoaded: @escaping @Sendable () throws -> Bool,
            launchSnapshot: @escaping @Sendable () -> ProviderLaunchSnapshot? = {
                LaunchAgent.launchSnapshot()
            },
            providerStillLoaded: @escaping @Sendable () -> Bool = { true },
            processAlive: @escaping @Sendable (Int32) -> Bool = daemonProcessAlive,
            terminateStaleLockOwner:
                @escaping @Sendable (UpdateProcessLock.Owner) -> Bool = { _ in false },
            isPastTickDeadline: @escaping @Sendable () -> Bool = { false },
            log: @escaping @Sendable (String) -> Void
        ) {
            self.kickstartIfLoaded = kickstartIfLoaded
            self.launchSnapshot = launchSnapshot
            self.providerStillLoaded = providerStillLoaded
            self.processAlive = processAlive
            self.terminateStaleLockOwner = terminateStaleLockOwner
            self.isPastTickDeadline = isPastTickDeadline
            self.log = log
        }
    }

    public enum DownOutcome: Sendable, Equatable {
        case restartIssued(updatedTo: String?, rolledBackTo: String?)
        case noLongerLoaded
        case retryBackoff(until: Double, reason: String)
        case lockBusy(String)
        case failed(String)
    }

    public enum HealthOutcome: Sendable, Equatable {
        case noCandidate
        case stabilizing(since: Double?)
        case inactiveCandidate(attemptStartedAt: Double)
        case promoted(version: String)
        case lockBusy
        case failed(String)
    }

    private let updater: SelfUpdater
    private let deps: Dependencies
    private let stabilizationSeconds: Double
    private let candidateStartupTimeoutSeconds: Double

    /// A candidate is judged hung only after the operator's configured
    /// startup preload window plus a safety margin. A raised
    /// `startup_preload_timeout_secs` must never make a healthy-but-slow
    /// new version charge false start failures and roll back.
    public static let candidateStartupSafetyMarginSeconds: Double = 180
    public static let candidateStartupTimeoutFloorSeconds: Double = 300

    public static func candidateStartupTimeout(
        preloadTimeoutSecs: UInt64
    ) -> Double {
        max(
            candidateStartupTimeoutFloorSeconds,
            Double(preloadTimeoutSecs) + candidateStartupSafetyMarginSeconds
        )
    }

    public init(
        updater: SelfUpdater,
        dependencies: Dependencies,
        stabilizationSeconds: Double = UpdateRecoveryState.defaultStabilizationSeconds,
        candidateStartupTimeoutSeconds: Double =
            WatchdogRecoveryService.candidateStartupTimeout(preloadTimeoutSecs: 120)
    ) {
        self.updater = updater
        self.deps = dependencies
        self.stabilizationSeconds = stabilizationSeconds
        self.candidateStartupTimeoutSeconds = candidateStartupTimeoutSeconds
    }

    /// Called only after the watchdog's outage grace expires. A pending
    /// candidate attempt is charged once, rollback is attempted at the third
    /// failure, then an allowed newer release is installed before kickstart.
    public func recoverDownProvider(
        autoUpdateEnabled: Bool,
        inactiveProviderIdentity: ProcessIdentity? = nil,
        providerProcessAlive: Bool = false,
        now: Double
    ) async -> DownOutcome {
        // Monotonic anchor for re-deriving the epoch time later in this call.
        // The awaited update/download below may legally take minutes (bounded
        // by the watchdog URLSession's 600s resource timeout); stamping the
        // candidate launch with the entry `now` would let a slow-but-successful
        // download consume the candidate's startup window before it even
        // launched, and the next tick would charge a false failed start.
        let entered = ContinuousClock.now
        func freshNow() -> Double {
            let elapsed = entered.duration(to: ContinuousClock.now)
            return now + Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) * 1e-18
        }
        let session: SelfUpdater.UpdateSession
        do {
            do {
                session = try updater.beginUpdateSession(
                    operation: "watchdog-recovery",
                    timeout: 1
                )
            } catch UpdateError.lockBusy(let reason, let owner) {
                guard let owner,
                      owner.processIdentity == inactiveProviderIdentity,
                      deps.terminateStaleLockOwner(owner)
                else {
                    throw UpdateError.lockBusy(
                        reason: reason,
                        owner: owner
                    )
                }
                session = try updater.beginUpdateSession(
                    operation: "watchdog-recovery-after-stale-owner",
                    timeout: 3
                )
            }
        } catch UpdateError.lockBusy(let reason, _) {
            // A LIVE process holds the update lease (flock auto-releases on
            // owner death) — it owns the provider lifecycle; defer to it.
            deps.log("update/recovery lock busy: \(reason)")
            return .lockBusy(reason)
        } catch {
            // Session infrastructure is unavailable (recovery dir or lock
            // file unopenable — full disk, permissions). Update and rollback
            // are impossible without it, but a plain launchd kickstart needs
            // none of that state: a degraded filesystem must not disable
            // basic crash recovery for an auto_restart provider.
            return restartWithoutRecovery(
                reason: "update recovery unavailable: \(error)"
            )
        }
        defer { session.release() }
        do {
            try session.recover(now: now)
        } catch {
            // An unreplayable journaled transaction: do NOT kickstart what
            // may be an unfinalized install tree. The next tick retries.
            let reason = "could not recover update state: \(error)"
            deps.log(reason)
            return .failed(reason)
        }
        guard deps.providerStillLoaded() else {
            return .noLongerLoaded
        }

        var rolledBackTo: String?
        do {
            var state = try session.readState()
            let beforeReconcile = state
            _ = state.reconcileLaunchIntent(
                snapshot: deps.launchSnapshot(),
                now: now
            )

            // A candidate that is still ALIVE and inside its config-derived
            // startup window (max(300, startup_preload_timeout_secs + 180)) is a
            // legitimately slow start (a long model preload writes no heartbeat
            // yet), NOT a failed launch. The generic down-grace must defer to
            // that window: do not charge a failed start and do not restart the
            // candidate. A DEAD candidate (providerProcessAlive == false) is
            // still charged and restarted so a real crash-loop rolls back.
            if providerProcessAlive,
               let candidate = state.candidate,
               let attemptStartedAt = candidate.attemptStartedAt,
               now - attemptStartedAt < candidateStartupTimeoutSeconds
            {
                if state != beforeReconcile { try session.writeState(state) }
                let until = attemptStartedAt + candidateStartupTimeoutSeconds
                deps.log(
                    "v\(candidate.release.version) is alive and within its "
                        + "\(Int(candidateStartupTimeoutSeconds))s startup window; deferring restart")
                return .retryBackoff(
                    until: until,
                    reason: "candidate still within startup window"
                )
            }

            if let count = state.recordPendingAttemptFailure(now: now) {
                try session.writeState(state)
                deps.log(
                    "v\(state.candidate?.release.version ?? "unknown") failed start \(count)/\(UpdateRecoveryState.rollbackThreshold)")
            }

            if state.isCandidateRetryBackedOff(now: now) {
                return .retryBackoff(
                    until: state.candidate?.retryNotBefore ?? now,
                    reason: state.candidate?.rollbackBlockedReason
                        ?? "rollback retry backoff"
                )
            }

            // Once rollback has been refused, the expiry of its backoff permits
            // one more launch of the still-intact current install. A subsequent
            // failure increments the attempt counter and retries rollback with
            // a longer delay; the provider is not trapped permanently down.
            let retryCurrentAfterRollbackRefusal =
                state.candidate?.rollbackBlockedReason != nil
            if let candidate = state.candidate,
               candidate.failureCount >= UpdateRecoveryState.rollbackThreshold,
               !retryCurrentAfterRollbackRefusal
            {
                do {
                    let restored = try session.rollback(
                        now: now,
                        reason: "automatic rollback after \(candidate.failureCount) failed starts"
                    )
                    rolledBackTo = restored
                    deps.log(
                        "quarantined v\(candidate.release.version) and restored verified predecessor v\(restored)")
                    state = try session.readState()
                } catch {
                    let reason = "\(error)"
                    state.deferRetryAfterRollbackFailure(now: now, reason: reason)
                    try session.writeState(state)
                    let until = state.candidate?.retryNotBefore ?? (now + 300)
                    deps.log(
                        "rollback refused; current install preserved; retry after \(Int(max(0, until - now)))s: \(reason)")
                    return .retryBackoff(until: until, reason: reason)
                }
            }
        } catch {
            let reason = "could not attribute candidate failure: \(error)"
            deps.log(reason)
            return .failed(reason)
        }

        var updatedTo: String?
        // Safe point: rollback (if any) is fully committed and the journal is
        // clean. Skipping the network update here can never leave a partial
        // install; the restart below still proceeds on the current binary and
        // the next tick retries the update.
        if autoUpdateEnabled, deps.isPastTickDeadline() {
            deps.log(
                "tick budget exhausted before the update check; restarting the current install now and deferring the update to the next tick")
        } else if autoUpdateEnabled {
            let result = await updater.update(
                session: session,
                beforeInstall: deps.providerStillLoaded
            )
            switch result {
            case .updated(_, let to):
                updatedTo = to
                deps.log("installed signed v\(to) before restart")
            case .restartRequired(_, let to):
                updatedTo = to
                deps.log("v\(to) is already installed; retrying its pending restart")
            case .alreadyUpToDate:
                break
            case .quarantined(let version, let reason):
                deps.log("v\(version) remains quarantined; not reinstalling it: \(reason)")
            case .busy(let reason):
                // Impossible while this session owns the lock, but fail safe if
                // a future updater implementation changes session semantics.
                deps.log("update skipped because lock became busy: \(reason)")
            case .cancelled(let reason):
                deps.log("watchdog update cancelled: \(reason)")
                return .noLongerLoaded
            case .downloadFailed(let reason):
                deps.log("update check/download failed; restarting current install: \(reason)")
            case .hashMismatch(let expected, let got):
                deps.log(
                    "update artifact refused (bundle hash expected \(expected), got \(got)); restarting current install")
            case .replaceFailed(let reason):
                deps.log("update install refused; restarting current install: \(reason)")
                // The refusal may have stranded a journaled transaction that
                // already exchanged the live layout (e.g. a state-write
                // failure after the rename). Replay it NOW: kickstarting an
                // unfinalized tree would launch a candidate with no pending
                // attempt recorded, so its crash would never be charged
                // toward the rollback threshold.
                do {
                    try session.recover(now: freshNow())
                } catch {
                    let recoveryReason =
                        "post-refusal update recovery failed: \(error)"
                    deps.log(recoveryReason)
                    return .failed(recoveryReason)
                }
            }
        }

        do {
            var state = try session.readState()
            // Launch stamps use the CURRENT time, not the tick-entry `now`:
            // everything the startup window measures begins here, after any
            // slow download/install above has already elapsed.
            let launchNow = freshNow()
            if state.candidate?.pendingAttemptID == nil,
               state.candidate?.launchIntent == nil {
                _ = state.prepareLaunchIntent(
                    now: launchNow,
                    baseline: deps.launchSnapshot()
                )
                try session.writeState(state)
            }

            do {
                let started = try deps.kickstartIfLoaded()
                guard started else {
                    state.cancelPendingAttempt()
                    try session.writeState(state)
                    return .noLongerLoaded
                }
                _ = state.markLaunchIssued(now: launchNow)
                try session.writeState(state)
            } catch {
                state.cancelPendingAttempt()
                try session.writeState(state)
                throw error
            }
            return .restartIssued(updatedTo: updatedTo, rolledBackTo: rolledBackTo)
        } catch {
            let reason = "provider kickstart failed: \(error)"
            deps.log(reason)
            return .failed(reason)
        }
    }

    /// Degraded-mode restart when the update/recovery session cannot even be
    /// opened: no state is read or written (it is unreachable), no failure is
    /// attributed, only the launchd kickstart runs. Provider availability
    /// outranks update bookkeeping when the filesystem is failing.
    private func restartWithoutRecovery(reason: String) -> DownOutcome {
        deps.log(reason + "; issuing restart-only kickstart without update recovery")
        guard deps.providerStillLoaded() else { return .noLongerLoaded }
        do {
            let started = try deps.kickstartIfLoaded()
            guard started else { return .noLongerLoaded }
            return .restartIssued(updatedTo: nil, rolledBackTo: nil)
        } catch {
            let kickstartReason = "provider kickstart failed: \(error)"
            deps.log(kickstartReason)
            return .failed(kickstartReason)
        }
    }

    /// Promote a candidate only after launchd says it is running and a daemon
    /// state heartbeat from that exact version remains fresh for the full
    /// stabilization window.
    public func observeHealthyProvider(
        providerRunning: Bool,
        daemonState: DaemonState?,
        now: Double
    ) -> HealthOutcome {
        let session: SelfUpdater.UpdateSession
        do {
            session = try updater.beginUpdateSession(
                operation: "watchdog-health",
                timeout: 0
            )
            try session.recover(now: now)
        } catch UpdateError.lockBusy {
            return .lockBusy
        } catch {
            return .failed("\(error)")
        }
        defer { session.release() }

        do {
            var state = try session.readState()
            guard let candidate = state.candidate else { return .noCandidate }
            let freshMatchingHeartbeat: Bool
            if let daemonState {
                freshMatchingHeartbeat = providerRunning
                    && daemonState.version == candidate.release.version
                    && !daemonState.isStale(now: now)
                    && deps.processAlive(daemonState.pid)
            } else {
                freshMatchingHeartbeat = false
            }

            let before = state
            let promoted = state.observeCandidateHealth(
                healthySignal: freshMatchingHeartbeat,
                processStartedAt: daemonState?.startedAt,
                now: now,
                stabilizationSeconds: stabilizationSeconds
            )
            if state != before {
                try session.writeState(state)
            }
            if promoted {
                deps.log(
                    "v\(candidate.release.version) passed \(Int(stabilizationSeconds))s stabilization; promoted")
                return .promoted(version: candidate.release.version)
            }
            if !freshMatchingHeartbeat,
               providerRunning,
               candidate.pendingAttemptID != nil,
               let attemptStartedAt = candidate.attemptStartedAt,
               now - attemptStartedAt >= candidateStartupTimeoutSeconds
            {
                return .inactiveCandidate(attemptStartedAt: attemptStartedAt)
            }
            return .stabilizing(since: state.candidate?.healthySince)
        } catch {
            return .failed("\(error)")
        }
    }
}
