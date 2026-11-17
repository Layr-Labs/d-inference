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
/// - Local requests are admitted as usual.
///
/// Invariants:
/// - The pause itself cancels nothing: Darkbloom work accepted before it
///   finishes, with no drain bound (unlike an add-on hold). Only while one of
///   the owner's requests waits in an engine's queue does Darkbloom work on
///   that model that is still queued give way, to be served elsewhere
///   (`giveWayToOwner`); work the engine has admitted still finishes.
/// - An add-on hold outranks the pause. While both apply, the busy fields
///   describe the hold (`publishBusy`), and the pause goes on under it.
/// - `desired_models` waits. Whichever of a drain, a hold and the pause ends
///   last replays it (`replayDesiredModels`).
/// - Heartbeats go out only when the pause begins and ends, beside the usual
///   baseline. A local request's start and end are O(1) updates of
///   `MeFirstPolicy`, with no I/O.
/// - At most one timer: armed when the owner's idle time starts counting,
///   gone once the pause ends. With me first off, no timer or task exists.
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
    /// Darkbloom work and announces it with one event heartbeat; the end of
    /// the last one starts the idle countdown. Every edge is an O(1) update
    /// with no I/O, and nothing at all happens while me first is off.
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

    /// The owner's request on `modelId` is waiting in its engine's queue
    /// (`EngineV2Bridge.watchOwnerWait`). Each Darkbloom request on that
    /// model that is still queued gives way: it is cancelled and ends with the
    /// typed drain refusal (`drainRefusal`), with no retry charge or health
    /// strike. The coordinator re-routes it to another Mac, or answers its
    /// client with a retryable 429 when no other Mac can take it.
    /// - Only queued work: a request the engine has admitted, in its prompt or
    ///   past it, keeps its work and finishes
    ///   (`EngineV2Bridge.hasAdmitted(darkbloomRequest:)`). One not yet in the
    ///   engine, or put back in its queue, is queued.
    /// - Only before its first output: `InferenceCancellationToken.giveWay()`
    ///   fails once the request has claimed it, so a Darkbloom request that is
    ///   streaming is never touched.
    /// - Only the owner's requests on a Mac with me first on call it: the
    ///   closure that does exists only then (`acquireModelForLocal`).
    /// - A request still being admitted has no token yet and is skipped; the
    ///   owner's request asks again at its next look while it still waits.
    func giveWayToOwner(modelId: String) async {
        let bridge = modelSlots[modelId]?.engineV2
        for (requestId, model) in requestToModel where model == modelId {
            guard let token = await cancellationRegistry.token(for: requestId) else { continue }
            if let bridge, await bridge.hasAdmitted(darkbloomRequest: requestId) { continue }
            guard token.giveWay() else { continue }
            logger.info("Me first: Darkbloom request \(requestId) was still queued; it goes back to the network so your request can start")
            await handleCancellation(
                requestId: requestId, receivedFromCoordinator: false, localCause: .stoppedOnThisMac)
        }
    }

    /// Ends the pause once the owner's idle time has passed, and returns
    /// whether it ended. The resume timer calls it.
    @discardableResult
    func resumeIfOwnerIdle() -> Bool {
        guard meFirst?.tick(atMs: meFirstNowMs()) == .resumed else { return false }
        leaveOwnerPause()
        return true
    }

    /// Called for every fresh registration, before the connection's first
    /// event heartbeat (`setRetirementReconnectBarrier`). The register carried
    /// the owner's busy fields, and that heartbeat repeats the draining status.
    internal func reassertOwnerPauseAfterReconnect() {
        guard ownerPausesPublic else { return }
        // A pause whose idle time passed while the connection was down ends
        // here, and the connection's first heartbeat announces it.
        if meFirst?.tick(atMs: meFirstNowMs()) == .resumed {
            leaveOwnerPause(announce: false)
            return
        }
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

    /// Runs on the owner's first request, so it writes no file: the loop's
    /// regular daemon-state write (every 2 s while serving) carries the pause.
    private func enterOwnerPause() {
        state.ownerPausesPublic = true
        publishBusy()
        logger.info("Me first: Darkbloom requests pause while you use this Mac; the \(coordinatorRequestsInFlight) already running finish")
        // Announce now: routing stops on the status, not on refusals.
        if let client = coordinatorClient { Task { await client.sendEventHeartbeat() } }
    }

    /// `announce: false` when a heartbeat about to go out says it anyway.
    private func leaveOwnerPause(announce: Bool = true) {
        cancelMeFirstResumeTimer()
        state.ownerPausesPublic = false
        publishBusy()
        logger.info("Me first: Darkbloom requests resume; you have been idle for \((meFirst?.idleMs ?? 0) / 1_000) s")
        writeDaemonState()
        Task { await self.announceOwnerPauseEnd(heartbeat: announce) }
    }

    /// Announces the end of the pause, then replays the desired_models
    /// deferred during it. A drain or hold still on replays them when it ends.
    private func announceOwnerPauseEnd(heartbeat: Bool) async {
        if heartbeat { await coordinatorClient?.sendEventHeartbeat() }
        await replayDesiredModels(deferred: "while you used this Mac")
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
