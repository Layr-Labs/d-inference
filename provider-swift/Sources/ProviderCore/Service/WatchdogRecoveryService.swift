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
        /// Trip the crash-loop KV-backend guard: persist the on-disk record
        /// NOW and stage the rest (`KVBackendCrashLoopGuard.stageTrip`).
        /// `guardedVersion` is the version launchd will actually kickstart,
        /// resolved by the recovery flow: the pending candidate's release
        /// version while a candidate owns the live layout, otherwise
        /// `SelfUpdater.effectiveInstalledVersion` — the watchdog process's
        /// own compiled-in version can be stale after a self-update.
        /// The returned `StagedTrip` splits the side effects around the
        /// kickstart: `undo` (nil when the record never reached disk)
        /// restores the pre-trip disk state and is invoked ONLY when this
        /// recovery attempt ends without an issued kickstart (the counted
        /// restart never happened, so the guard must not strand); `emit`
        /// queues the ERROR trip event and is invoked exactly once, at
        /// kickstart success — the same point the undo is disarmed — so an
        /// undone trip leaves no telemetry trace. Injectable so the
        /// decision-flow tests can observe trips (and their ordering against
        /// the kickstart) without touching the real `~/.darkbloom`.
        public var tripKVBackendGuard:
            @Sendable (_ crashCount: Int, _ now: Double, _ guardedVersion: String)
                -> KVBackendCrashLoopGuard.StagedTrip
        /// Reports the version-scoped crash-loop chain this recovery attempt
        /// resolved: the effective counter value
        /// (`WatchdogPolicy.versionScopedCrashLoopCount` over the caller's
        /// raw count) and the installed version it is scoped to. The caller
        /// persists BOTH — but only when the outcome shows the restart was
        /// actually issued. A dependency rather than a return value because
        /// `DownOutcome` is pattern-matched by equality across the decision
        /// tests and the chain is orthogonal to the outcome shape.
        public var noteCrashLoopChain: @Sendable (_ count: Int, _ installedVersion: String) -> Void
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
            tripKVBackendGuard: @escaping @Sendable (Int, Double, String)
                -> KVBackendCrashLoopGuard.StagedTrip = {
                KVBackendCrashLoopGuard.stageTrip(
                    crashCount: $0, now: $1, guardedVersion: $2, lastKnownModel: nil)
            },
            noteCrashLoopChain: @escaping @Sendable (Int, String) -> Void = { _, _ in },
            log: @escaping @Sendable (String) -> Void
        ) {
            self.kickstartIfLoaded = kickstartIfLoaded
            self.launchSnapshot = launchSnapshot
            self.providerStillLoaded = providerStillLoaded
            self.processAlive = processAlive
            self.terminateStaleLockOwner = terminateStaleLockOwner
            self.isPastTickDeadline = isPastTickDeadline
            self.tripKVBackendGuard = tripKVBackendGuard
            self.noteCrashLoopChain = noteCrashLoopChain
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
        /// A candidate whose rollback was refused (blocked) has passed its
        /// retry backoff without producing a heartbeat; the caller must
        /// re-enter the recovery path to honor the retry.
        case blockedCandidateRetry(reason: String)
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
    ///
    /// `crashLoopRestartCount` is the consecutive crash-loop counter value
    /// THIS restart carries if issued (`WatchdogPolicy.crashLoopCount`,
    /// computed by the caller from the persisted watchdog state), BEFORE
    /// version scoping: this flow resolves the installed daemon version and
    /// rescopes the count through
    /// `WatchdogPolicy.versionScopedCrashLoopCount(_:recordedVersion:installedVersion:)`
    /// — `lastRestartVersion` is the persisted state's recorded version the
    /// scoping compares against. At `WatchdogPolicy.crashLoopTripThreshold`
    /// (of the SCOPED count) the KV-backend guard is persisted BEFORE the
    /// kickstart below — see the trip site for the precedence rules. The
    /// default 0 (below any threshold) keeps callers that do not track the
    /// chain, e.g. the healthy-path candidate re-entries, from ever tripping
    /// it: those handle a RUNNING-but-inert process, not the launchd death
    /// loop the guard exists for.
    public func recoverDownProvider(
        autoUpdateEnabled: Bool,
        inactiveProviderIdentity: ProcessIdentity? = nil,
        providerProcessAlive: Bool = false,
        crashLoopRestartCount: Int = 0,
        lastRestartVersion: String? = nil,
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
        // True while a pending update candidate still has a VIABLE rollback
        // path — the state that must suppress the crash-loop backend guard
        // below. Read after the rollback attempt so a rollback that just
        // committed (candidate cleared) or was refused (blocked reason set)
        // is judged on its outcome, not its intent.
        var candidateOwnsRecovery = false
        // The version the backend guard binds if tripped below: the version
        // launchd will actually kickstart — a pending candidate's release
        // version when one owns the live layout, otherwise the INSTALLED
        // version resolved exactly the way `SelfUpdater.checkForUpdate`
        // resolves it (same seam, same arithmetic). This process's own
        // compiled-in version is only the floor — the persistent watchdog
        // keeps running its old executable image after it installs and
        // promotes a newer release, and a guard stamped with the stale
        // watchdog version would never bind the new daemon that is actually
        // crash-looping (it would even be deleted at its startup as stale).
        var guardedVersion = updater.currentVersion
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
            candidateOwnsRecovery = state.candidate != nil
                && state.candidate?.rollbackBlockedReason == nil
            // The version launchd will actually kickstart. While a pending
            // candidate exists, the LIVE layout is the candidate's:
            // `installCandidate` exchanges the layout at install time and
            // `state.current` keeps naming the predecessor until promotion —
            // so neither `current` nor this watchdog's own process version
            // (commonly that same predecessor) can identify it. This matters
            // exactly when the candidate's rollback was REFUSED: that is the
            // only candidate state that can reach the trip below, the guard
            // is then the one automated mitigation left, and a guard stamped
            // with the predecessor would read as stale to the relaunched
            // candidate daemon and never bind (it would even be deleted at
            // startup via `clearIfStale`). Resolved AFTER the rollback
            // attempt so a rollback that just committed (candidate cleared,
            // `current` restored) resolves the restored predecessor — never
            // a version that is already leaving the box.
            if let candidate = state.candidate {
                guardedVersion = candidate.release.version
            } else {
                guardedVersion = SelfUpdater.effectiveInstalledVersion(
                    processVersion: updater.currentVersion,
                    recorded: state.current?.version)
            }
        } catch {
            let reason = "could not attribute candidate failure: \(error)"
            deps.log(reason)
            return .failed(reason)
        }

        // Version-scope the chain: a chain recorded against a DIFFERENT
        // installed version (a promotion or rollback landed since the last
        // restart) resets — the new binary's first short-lived crash must
        // not inherit the old binary's count and instantly guard the release
        // that was shipped to fix it. Report the scoped chain (count +
        // version) so the caller persists exactly what this flow acted on,
        // but only if the restart is actually issued below.
        let scopedCrashLoopCount = WatchdogPolicy.versionScopedCrashLoopCount(
            crashLoopRestartCount,
            recordedVersion: lastRestartVersion,
            installedVersion: guardedVersion)
        if scopedCrashLoopCount != crashLoopRestartCount {
            deps.log(
                "crash-loop chain reset \(crashLoopRestartCount) → \(scopedCrashLoopCount): "
                    + "the installed version changed to v\(guardedVersion) "
                    + "(chain was recorded against "
                    + (lastRestartVersion.map { "v\($0)" } ?? "no version — legacy state")
                    + ")")
        }
        deps.noteCrashLoopChain(scopedCrashLoopCount, guardedVersion)

        // Crash-loop KV-backend guard (v0.8.0). The caller counted this
        // restart as the Nth consecutive crash-loop-shaped one; at the
        // threshold the guard record is persisted HERE — before the update
        // check and the kickstart — so the daemon this very tick relaunches
        // already resolves `.auto` to contiguous on its first model load.
        // Tripping after the kickstart would race the relaunched daemon's
        // model preload and lose: that boot would just be crash N+1.
        //
        // PRECEDENCE — the update-recovery candidate rollback WINS, for two
        // reasons. First, it fixes more: rolling the BINARY back to the
        // verified predecessor also fixes paged, because the pre-0.8.0
        // predecessor resolves `.auto` to contiguous. Second, flipping both
        // levers at once would strand a guard record for a version about to
        // leave the box, and the two automations must not fight over one
        // incident. So: a rollback that just committed (`rolledBackTo`)
        // suppresses the trip, and a pending candidate with a viable
        // rollback path (`candidateOwnsRecovery`) suppresses it while the
        // candidate's own failure counter — same threshold of 3, charged on
        // the same restarts — walks toward that rollback. A candidate whose
        // rollback was REFUSED (blocked reason set) has already lost its fix
        // path, so the backend guard is the one automated mitigation left
        // and may trip.
        // The write is BOUND to the kickstart: any exit below that does not
        // issue the restart rolls it back (`rollBackTripUnlessKickstarted`)
        // — the chain counter is only persisted for issued restarts, so a
        // no-restart exit means the counted third restart never happened and
        // a stranded guard would force contiguous on the next manual start
        // for a trip that never completed. The undo restores the pre-trip
        // disk state, so it can never delete a pre-existing guard from an
        // earlier completed trip. The trip EVENT is likewise deferred to the
        // kickstart (`pendingTripEmission`, fired where the undo is
        // disarmed): the undo can restore the disk but cannot retract a
        // queued event, and an undone trip that had already queued one would
        // ship a false incident signal on the next healthy boot.
        var undoTrip: (@Sendable () -> Void)?
        var pendingTripEmission: (@Sendable () -> Void)?
        if scopedCrashLoopCount >= WatchdogPolicy.crashLoopTripThreshold,
            rolledBackTo == nil,
            !candidateOwnsRecovery
        {
            let staged = deps.tripKVBackendGuard(scopedCrashLoopCount, now, guardedVersion)
            // Emitted even when the record write failed (the event carries
            // the could-not-persist warning — the fleet's only signal that a
            // box is looping unguarded), but still only for an issued
            // kickstart.
            pendingTripEmission = staged.emit
            if staged.persisted {
                undoTrip = staged.undo
                deps.log(
                    "crash-loop backend guard tripped after \(scopedCrashLoopCount) short-uptime "
                        + "restarts — `.auto` resolves contiguous on this box until the next "
                        + "release or `darkbloom doctor --clear-backend-guard`")
            } else {
                deps.log(
                    "crash-loop backend guard could not be persisted (check ~/.darkbloom) — "
                        + "a slot with an explicit paged selection will keep resolving "
                        + "paged and the crash loop may continue")
            }
        }
        // Every failure exit below runs through this. It only acts while the
        // kickstart has NOT been issued: the moment `kickstartIfLoaded()`
        // returns true the undo is disarmed (`undoTrip = nil` at the call
        // site), because launchd has already counted the restart — a
        // bookkeeping failure after that point must not strip the guard from
        // the daemon that is about to boot.
        func rollBackTripUnlessKickstarted(_ outcome: DownOutcome) -> DownOutcome {
            if let undoTrip {
                undoTrip()
                deps.log(
                    "crash-loop backend guard rolled back — recovery ended without an "
                        + "issued restart, so the counted restart never happened")
            }
            return outcome
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
                return rollBackTripUnlessKickstarted(.noLongerLoaded)
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
                    return rollBackTripUnlessKickstarted(.failed(recoveryReason))
                }
            }
        }

        do {
            var state = try session.readState()
            // Launch stamps use the CURRENT time, not the tick-entry `now`:
            // everything the startup window measures begins here, after any
            // slow download/install above has already elapsed.
            //
            // Every write below is gated on an ACTUAL state mutation. With no
            // candidate, all of the launch bookkeeping is a no-op, and an
            // ordinary crashed provider must be restartable even when the
            // recovery state has become unwritable (full disk, permissions) —
            // a vacuous write must never gate the bare kickstart.
            let launchNow = freshNow()
            func writeIfChanged(
                _ state: UpdateRecoveryState,
                before: UpdateRecoveryState
            ) throws {
                if state != before {
                    try session.writeState(state)
                }
            }
            if state.candidate?.pendingAttemptID == nil,
               state.candidate?.launchIntent == nil {
                let before = state
                _ = state.prepareLaunchIntent(
                    now: launchNow,
                    baseline: deps.launchSnapshot()
                )
                try writeIfChanged(state, before: before)
            }

            do {
                let started = try deps.kickstartIfLoaded()
                guard started else {
                    let before = state
                    state.cancelPendingAttempt()
                    try writeIfChanged(state, before: before)
                    return rollBackTripUnlessKickstarted(.noLongerLoaded)
                }
                // The counted restart is now REAL: launchd has been told to
                // relaunch. Disarm the trip undo — if the launch bookkeeping
                // below throws (full disk, unwritable recovery dir) this
                // attempt still returns `.failed`, but undoing the guard
                // would boot the relaunched daemon paged and guardless while
                // the chain counter (persisted only for `.restartIssued`)
                // did not advance either. The trip event fires HERE, for the
                // same reason in the other direction: only a trip whose
                // counted restart actually happened may reach the fleet's
                // alerting.
                undoTrip = nil
                pendingTripEmission?()
                pendingTripEmission = nil
                let before = state
                _ = state.markLaunchIssued(now: launchNow)
                try writeIfChanged(state, before: before)
            } catch {
                let before = state
                state.cancelPendingAttempt()
                try writeIfChanged(state, before: before)
                throw error
            }
            return .restartIssued(updatedTo: updatedTo, rolledBackTo: rolledBackTo)
        } catch {
            let reason = "provider kickstart failed: \(error)"
            deps.log(reason)
            // Pre-kickstart throws: the chain counter is not advanced for a
            // failed kickstart, so the next tick recomputes the same count
            // and re-trips — rolling back keeps disk state and counter
            // consistent in between. Post-kickstart bookkeeping throws reach
            // here too, but the undo was disarmed at the kickstart, so the
            // guard survives them.
            return rollBackTripUnlessKickstarted(.failed(reason))
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
            // A refused rollback clears `pendingAttemptID`, so the branch
            // above can never fire again for that candidate — and a hung-but-
            // alive process keeps launchd reporting "running", so the down
            // path never fires either. Without this bridge, the expiry of
            // `retryNotBefore` is never honored and the host stays wedged on
            // a hung candidate forever. (A pending fresh install without a
            // blocked reason is deliberately NOT bridged: the provider's own
            // update loop restarts into it; the watchdog must never kill a
            // serving provider to force an update.)
            if !freshMatchingHeartbeat,
               providerRunning,
               candidate.pendingAttemptID == nil,
               let blockedReason = candidate.rollbackBlockedReason,
               !state.isCandidateRetryBackedOff(now: now)
            {
                return .blockedCandidateRetry(reason: blockedReason)
            }
            return .stabilizing(since: state.candidate?.healthySince)
        } catch {
            return .failed("\(error)")
        }
    }
}
