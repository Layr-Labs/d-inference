import Foundation

/// Me first, the owner pause: while the owner uses this Mac through its local
/// API, the provider stays registered and keeps its models loaded, but takes
/// no Darkbloom work.
///
/// - Heartbeats say `draining` with `busy_reason: "owner"`; coordinators that
///   do not know the reason treat it as a plain drain.
/// - A dispatch that races the heartbeat gets the typed `capacity / 503 /
///   draining` refusal, which coordinators fail over without a retry or a
///   derate. `load_model` and `prefetch_model` get the drain failures,
///   Autopilot commands are busy, and capacity quotes refuse.
/// - `desired_models` waits, and is replayed when the pause ends.
/// - Local requests are admitted as usual, and Darkbloom work accepted before
///   the pause finishes.
///
/// It is event-driven and costs next to nothing. A local request's start and
/// end are O(1) updates of `MeFirstPolicy`. Heartbeats go out only when the
/// pause begins and ends, beside the usual baseline. The one timer is armed
/// when the owner's idle time starts counting and is gone once the pause
/// ends. With me first off, nothing here runs.
extension ProviderLoop {
    /// Darkbloom work is paused for the owner.
    var ownerPausesPublic: Bool { meFirst?.isPausingPublic == true }

    /// Turns me first on for this serving process, with the owner's idle time
    /// (`[local] me_first_idle_minutes`). The first call wins: a changed
    /// setting applies at the next start.
    func enableMeFirst(idle: Duration) {
        guard meFirst == nil else { return }
        let policy = MeFirstPolicy(idleMs: Self.milliseconds(idle))
        meFirst = policy
        logger.info("Me first is on: Darkbloom requests pause while you use this Mac, and resume \(policy.idleMs / 1_000) s after your last request")
        writeDaemonState()
    }

    /// A local request acquired a model on this Mac (`.start`) or released it
    /// (`.end`); every start is paired with one end. The first start pauses
    /// Darkbloom work and announces it at once; the end of the last one
    /// starts the idle countdown. Anything else is an O(1) update with no I/O,
    /// and nothing at all while me first is off.
    func noteLocalUse(_ use: MeFirstPolicy.LocalUse) {
        guard meFirst != nil else { return }
        let now = meFirstNowMs()
        switch use {
        case .start:
            if meFirst?.localStarted(atMs: now) == .paused { enterOwnerPause() }
        case .end:
            meFirst?.localEnded(atMs: now)
            if meFirst?.resumesAtMs != nil { armMeFirstResumeTimer() }
        }
    }

    /// Ends the pause once the owner's idle time has passed, and returns
    /// whether it ended. The resume timer calls it, and so does a fresh
    /// coordinator connection.
    @discardableResult
    func resumeIfOwnerIdle() -> Bool {
        guard meFirst?.tick(atMs: meFirstNowMs()) == .resumed else { return false }
        leaveOwnerPause()
        return true
    }

    /// Called for every fresh registration. The register carried the owner's
    /// busy fields, and the connection's first event heartbeat
    /// (`setRetirementReconnectBarrier`) repeats the draining status. A pause
    /// whose idle time passed while the connection was down ends here.
    internal func reassertOwnerPauseAfterReconnect() {
        guard ownerPausesPublic, !resumeIfOwnerIdle() else { return }
        logger.info("Me first: Darkbloom requests stay paused on the new coordinator connection")
    }

    /// Me first as `status` reads it; nil while off.
    var meFirstSnapshot: MeFirstSnapshot? {
        guard let policy = meFirst else { return nil }
        return policy.snapshot(darkbloomRequestsFinishing: policy.isPausingPublic ? coordinatorRequestsInFlight : 0)
    }

    /// The one writer of `state.busy`, which every heartbeat and registration
    /// copies: an add-on hold outranks the owner pause.
    internal func publishBusy() {
        state.busy = ProviderBusy.publishing(
            addonHold: addonHolds.oldest.map { ProviderBusy(reason: .addon, sinceMs: $0.sinceMs, addon: $0.addon) },
            ownerPause: meFirst?.sinceMs.map { ProviderBusy(reason: .owner, sinceMs: $0) })
    }

    // MARK: - Transitions

    private func enterOwnerPause() {
        state.ownerPausesPublic = true
        publishBusy()
        logger.info("Me first: Darkbloom requests pause while you use this Mac; the \(coordinatorRequestsInFlight) already running finish")
        // Announce now: routing stops on the status, not on refusals.
        if let client = coordinatorClient { Task { await client.sendEventHeartbeat() } }
        writeDaemonState()
    }

    private func leaveOwnerPause() {
        cancelMeFirstResumeTimer()
        state.ownerPausesPublic = false
        publishBusy()
        logger.info("Me first: Darkbloom requests resume; you have been idle for \((meFirst?.idleMs ?? 0) / 1_000) s")
        writeDaemonState()
        Task { await self.announceOwnerPauseEnd() }
    }

    /// Announces the routable status, then replays the desired_models
    /// deferred during the pause. A drain or hold still on replays them when
    /// it ends.
    private func announceOwnerPauseEnd() async {
        await coordinatorClient?.sendEventHeartbeat()
        guard !ownerPausesPublic, !servingDrain.refusing, !addonHoldActive,
              let entries = deferredDesiredModels, let send = outboundSend else { return }
        deferredDesiredModels = nil
        logger.info("Replaying desired_models deferred while you used this Mac (\(entries.count) entr(ies))")
        await reconcileDesiredModels(entries, send: send)
    }

    // MARK: - Resume timer

    private func armMeFirstResumeTimer() {
        guard meFirstResumeTimer == nil else { return }
        meFirstTimerGeneration &+= 1
        let generation = meFirstTimerGeneration
        meFirstResumeTimer = Task { [weak self] in await self?.runMeFirstResumeTimer(generation: generation) }
    }

    /// Sleeps until the owner's idle time is up, then resumes. A request that
    /// starts or ends meanwhile only moves the deadline: on waking the timer
    /// reads it again and sleeps on, or ends while a request runs (the next
    /// end arms it again). One sleep never exceeds the idle time, so a clock
    /// that went back is read again then.
    private func runMeFirstResumeTimer(generation: UInt64) async {
        defer { if meFirstTimerGeneration == generation { meFirstResumeTimer = nil } }
        while meFirstTimerGeneration == generation, !Task.isCancelled {
            if resumeIfOwnerIdle() { return }
            guard let policy = meFirst, let deadline = policy.resumesAtMs else { return }
            let (remaining, overflow) = deadline.subtractingReportingOverflow(meFirstNowMs())
            let wait = overflow ? policy.idleMs : min(remaining, policy.idleMs)
            try? await Task.sleep(nanoseconds: UInt64(max(wait, 1)) * 1_000_000)
        }
    }

    internal func cancelMeFirstResumeTimer() {
        meFirstTimerGeneration &+= 1
        meFirstResumeTimer?.cancel()
        meFirstResumeTimer = nil
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        let (seconds, attoseconds) = duration.components
        return seconds * 1_000 + attoseconds / 1_000_000_000_000_000
    }
}
