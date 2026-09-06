// Cancellation and orderly release of engine-owned resources.

import Foundation
import MLXLMCommon
import ProviderCoreFoundation

extension EngineV2Bridge {
    // MARK: - Cancel / shutdown

    /// Cancel by provider request-id. Prompt per the v2 contract: the
    /// in-flight step completes and the row is dropped O(1); the engine
    /// then delivers `.finished(.cancelled)` on the request's stream,
    /// which drives the normal bookkeeping/teardown in the pump.
    public func cancel(requestId: String) {
        // Same order as `cancelIfOwned`: an admitted row's real completion
        // count wins; only a row that is still pending gets the 0 seed (a
        // request briefly sits in both maps between `active[id] = …` and the
        // pending id's removal, and the seed must never shadow the count).
        if let state = active[requestId] {
            snapshotTokensAtCancel(state)
        } else if pendingSubmissionIDs.contains(requestId) {
            latchPendingCancel(id: requestId)
        }
        if let cbv2Id = idMap[requestId] {
            ownedEngine?.cancel(cbv2Id)
        }
    }

    /// The outer handler has already classified a partial cancellation. Stop
    /// its exact native row before waiting: the SSE stream is still retained,
    /// so its deallocation cannot be the cancellation trigger for this wait.
    /// Profile identity binds the coordinator request to the current internal
    /// id without changing the earlier first-cancel accounting snapshot.
    func settleCancelledStream(
        profile: RequestProfileBuilder,
        usageSignal: EngineV2RequestUsageSignal
    ) async {
        if let requestID = active.first(where: { $0.value.profile === profile })?.key {
            cancel(requestId: requestID)
        }
        #if DEBUG
        let onWait = _testOnCancelledSettlementWait
        _testOnCancelledSettlementWait = nil
        onWait?()
        #endif
        await usageSignal.waitForTerminalObservation()
    }

    /// A cancel reached the bridge while `id` is still pending engine
    /// admission: latch it (the existing minted-id latch — the submission is
    /// REFUSED at its next pre-submit check, strictly before the engine sees
    /// the row, or torn down at atomic admission on the deadline path) and
    /// seed the `tokens_after_cancel` baseline at 0, since the row has
    /// produced nothing yet. First cancel wins; one lock, cancel path only.
    func latchPendingCancel(id: String) {
        pendingCancellationIDs.insert(id)
        guard let profile = pendingProfiles[id] else { return }
        profile.update { f, _ in
            if f.count(.tokensAtCancel) == nil {
                f.set(.tokensAtCancel, 0)
            }
        }
    }

    /// RULE: `tokens_after_cancel = 0` is written only when the engine
    /// PROVABLY never ran the row — the pre-submit refusal (latched before the
    /// engine saw it) and the `.deadlineUnreachable` verdict (never admitted).
    /// Once a row was admitted (the `.admitted` teardown, the
    /// `CBv2FirstTokenAdmissionCancellation` catch) an in-flight step may
    /// have produced a token before the cancel was processed and no pump will
    /// reconcile it, so the field is OMITTED rather than fabricated. Writes
    /// only when a cancel was actually received (baseline present).
    func recordCancelledBeforeGeneration(_ profile: RequestProfileBuilder?) {
        profile?.update { f, _ in
            if f.count(.tokensAtCancel) != nil, f.count(.tokensAfterCancel) == nil {
                f.set(.tokensAfterCancel, 0)
            }
        }
    }

    /// Profiler `tokens_after_cancel`: snapshot the completion count the
    /// moment a cancel reaches the bridge (first cancel wins); the delta is
    /// computed at finish. One lock, cancel path only.
    private func snapshotTokensAtCancel(_ state: ActiveRequestState) {
        guard let profile = state.profile else { return }
        let tokensNow = Int64(state.completionTokens)
        profile.update { f, _ in
            if f.count(.tokensAtCancel) == nil {
                f.set(.tokensAtCancel, tokensNow)
            }
        }
    }

    /// Runtime fan-out helper: cancel iff this bridge owns the request-id.
    func cancelIfOwned(requestId: String, profile: RequestProfileBuilder? = nil) -> Bool {
        if let cbv2Id = idMap[requestId], let engine = ownedEngine {
            if let state = active[requestId] {
                snapshotTokensAtCancel(state)
            } else if pendingSubmissionIDs.contains(requestId) {
                latchPendingCancel(id: requestId)
            }
            engine.cancel(cbv2Id)
            return true
        }
        // Miss path — the expected case for a COORDINATOR cancel: the
        // coordinator id never matches the `req-…` id the engine tracks (see
        // ProviderLoop+Cancellation). The request's profile is the one handle
        // both sides share, so match on its identity. O(rows), cancel path only.
        guard let profile else { return false }
        // Admitted row: take the `tokens_after_cancel` snapshot NOW, at
        // cancel receipt, instead of at Task-cancellation teardown.
        // Cancellation semantics unchanged (still Task-propagation driven).
        if let state = active.values.first(where: { $0.profile === profile }) {
            snapshotTokensAtCancel(state)
            return false
        }
        // Still pending engine admission: seed the zero baseline and latch
        // the cancellation so the row is cancelled the moment submit returns
        // (ordinary path) or torn down at atomic admission (deadline path).
        // Owned — nothing else can hold this profile, so stop scanning.
        if let pendingId = pendingProfiles.first(where: { $0.value === profile })?.key {
            latchPendingCancel(id: pendingId)
            return true
        }
        return false
    }

    /// Graceful drain (unload / process shutdown): running requests finish,
    /// new submissions are rejected by the engine.
    ///
    /// The per-request pump tasks are tracked (`pumpTasks`) and cancelled here
    /// so none outlives the bridge. Cancellation makes each pump's
    /// `for await event in events` resume with nil (AsyncStream is
    /// cancellation-aware), so the pump hits its teardown path — yielding the
    /// closed-stream sentinel and releasing per-request state — instead of
    /// leaking. We cancel BEFORE draining the engine so a wedged engine stream
    /// can't keep a pump (and its KV reservation) alive past shutdown, then
    /// await the engine drain.
    public func shutdown() async {
        let statsTask = prefixCacheStatsTask
        prefixCacheStatsTask = nil
        prefixCacheTelemetry.close()
        statsTask?.cancel()
        slotPostureTask?.cancel()
        slotPostureTask = nil
        let live = pumpTasks
        pumpTasks.removeAll()
        for task in live.values { task.cancel() }
        // Cancel queued disk transfers without waiting on engine callbacks.
        ssdHybridCheckpointStore?.close()
        if let engine = ownedEngine {
            await engine.shutdown()
        }
        for task in live.values {
            await task.value
        }
        _ = await statsTask?.value
        // The bridge may remain in a local teardown variable; explicitly drop
        // the concrete engine so target and assistant ownership does not.
        ownedEngine = nil
        prefixCacheEvidenceSequencer?.shutdown()
        residentPrefixCacheEvidenceSequencer?.shutdown()
        residentPrefixCacheEvidence?.close()
        // SSD tier teardown AFTER the engine drain: queued donation writes
        // are dropped, staging pins/reservations released, on-disk files
        // KEPT — durable warmth across unload/restart is the feature.
        await ssdPrefixCache?.closeAndWait()
        await ssdHybridCheckpointStore?.closeAndWait()
    }
}
