/// ProviderLoop -- request cancellation + in-flight drain.
///
/// Coordinator/local cancellation, cancel-all on disconnect, per-request
/// cleanup, and the bounded in-flight drain used during shutdown/update.

import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXLMServer
import MLXVLM
#if canImport(os)
import os
#endif

extension ProviderLoop {
    // MARK: - Cancellation

    internal func handleCancellation(requestId: String, receivedFromCoordinator: Bool = true) async {
        // Cheap by design. The coordinator sends a cancel after EVERY
        // committed request and re-cancels suspected zombies every 10 s, and
        // every cancel shares the serial event loop with new inference
        // requests — so an id this loop has never seen (or has already
        // finished) must cost nothing: no actor hop, no capacity rebuild,
        // no info log.
        let hadInflightTask = inflightTasks[requestId] != nil
        let hadModelReservation = requestToModel[requestId] != nil
        let profile = inflightProfiles[requestId]
        guard hadInflightTask || hadModelReservation || profile != nil else {
            logger.debug("Cancel for unknown or finished request: \(requestId)")
            return
        }
        logger.info("Cancelling request: \(requestId)")
        if receivedFromCoordinator && (hadInflightTask || hadModelReservation) {
            stats.incrementCancellationsReceived()
        }
        // Profiler: stamp cancel receipt and derive the lifecycle stage from
        // the stamps present right now (one lock). The stage counters count
        // COORDINATOR cancels only — a disconnect-driven cancel-all is not
        // a client decision.
        if let profile,
            let stage = profile.markCancelReceived(),
            receivedFromCoordinator
        {
            stats.incrementCancelStage(stage)
        }

        // The ONE statement that stops a coordinator-routed generation, so it
        // runs BEFORE any suspension point in this method:
        //
        //   ProviderLoop.task.cancel()
        //     -> `for try await frame in frames` ends (nil-end or
        //        CancellationError; the handler checks `Task.isCancelled`
        //        on every settle path so the partial-settle billing does not
        //        depend on the registry hop below having landed)
        //     -> the detached task exits, the `frames` AsyncThrowingStream
        //        is deallocated, its `onTermination` fires
        //     -> MLXOpenAIService.streamChatCompletionFrames's inner
        //        task is cancelled, its iteration on the engine stream
        //        exits, the engine stream is deallocated, its
        //        `onTermination` fires
        //     -> MultiModelBatchSchedulerEngine.streamChatCompletion's
        //        `onTermination` cancels the bridge's internal id.
        if let task = inflightTasks.removeValue(forKey: requestId) {
            task.cancel()
        }

        // Load-window tombstone: `handleInferenceRequest` re-checks
        // `requestToModel` after `ensureModelLoaded` returns and emits the
        // 499 terminal instead of spawning generation.
        if requestToModel.removeValue(forKey: requestId) != nil {
            if !hadInflightTask {
                stats.incrementCancelDuringModelLoad()
            }
            powerAssertion.release()
        }
        syncWarmModelState()

        // Defense in depth: the explicit `token.isCancelled` check inside the
        // streaming loop also fires on the next iteration (both paths reach
        // the same teardown).
        await cancellationRegistry.cancel(requestId: requestId)

        // Second, task-independent stop path. MLXLMServer mints the engine's
        // provider id (`req-…`) per request, so the coordinator id misses the
        // bridge's id map; the request's profile is the one handle both
        // sides share, and the owning bridge matches on its identity: it
        // takes the `tokens_after_cancel` snapshot at cancel receipt AND
        // cancels the engine row, so the row is dropped at the next step
        // boundary even if the detached task is wedged in synchronous work.
        // Runs AFTER `task.cancel()` — it is the slower path (one actor hop
        // per live bridge). The zero-slot guard avoids the hop entirely. A
        // miss means "never submitted" or "already finished" — the latter
        // records `tokens_after_cancel = 0` rather than omitting the field.
        if hasEngineV2Slots {
            let owned = await engineV2Runtime.cancel(requestId: requestId, profile: profile)
            if !owned {
                profile?.recordTokensAfterCancelIfFinished()
            }
        }
        // No `updateAggregateCapacity()` here: `finishInflightRequest` runs
        // it when the cancelled task exits, and a request cancelled inside
        // the load window never held engine capacity (the 2 s capacity tick
        // covers its `in_admission` counter).
    }

    /// Terminal for a cancel honored inside the load window — the request
    /// was accepted but its generation task was never spawned, so neither
    /// of the detached task's terminals can fire. Same 499 `cancelled` shape
    /// as the pre-output cancel the detached task emits, so the coordinator
    /// can measure cancel→terminal latency for exactly the head-of-line-
    /// blocked case (it has already dropped its pending entry; the terminal
    /// is health-neutral and only ever observed as a late one).
    internal func sendCancelledInLoadWindowTerminal(
        requestId: String,
        profile: RequestProfileBuilder,
        send: SendHandle,
        lookupReceiptFinalizer: PrefixCacheLookupReceiptFinalizer
    ) {
        profile.mark(.cancelAborted)
        profile.update { f, now in f.mark(.terminalBuilt, offsetUs: now) }
        lookupReceiptFinalizer.sendTerminal(
            .inferenceError(
                requestId: requestId,
                failure: InferenceFailure(
                    code: .cancelled,
                    statusCode: 499,
                    terminalCause: .cancelled),
                profile: profile),
            fallbackFailure: .policy,
            send: send)
    }

    internal func cancelAllInflight() async {
        // Disconnect-driven: the coordinator will not route responses for a
        // dead connection, so stop every generation NOW — one synchronous
        // sweep, no per-id actor hops. Each task's defer still runs
        // `finishInflightRequest` (registry finish + capacity rebuild), and
        // Task propagation reaches the engine rows exactly as for a single
        // cancel.
        for task in inflightTasks.values {
            task.cancel()
        }
        inflightTasks.removeAll()
        completedBeforeTaskRegistration.removeAll()
        inflightProfiles.removeAll()
        if !requestToModel.isEmpty {
            powerAssertion.releaseAll()
        }
        // Preserve wedge-recovery pins: they are NOT inflight requests —
        // they keep the idle monitor and the eviction filters off a slot
        // whose engine is mid-rebuild (ProviderLoop+EngineV2Liveness), and
        // the recovery removes its own pin when it finishes. A
        // disconnect-driven mass cancel must not strip that protection.
        // (Pins never hold a power assertion, so releaseAll is unaffected.)
        requestToModel = requestToModel.filter {
            $0.key.hasPrefix(Self.engineV2RecoveryPinPrefix)
        }
        syncWarmModelState()
    }

    internal func finishInflightRequest(requestId: String) async {
        let hadRegisteredTask = inflightTasks.removeValue(forKey: requestId) != nil
        let modelId = requestToModel.removeValue(forKey: requestId)
        // Dropping the map entry does not disarm the builder's
        // `onTokensAfterCancel` hook: the bridge holds the builder through
        // `ActiveRequestState.profile` until its own finish, and the hook
        // captures only the process-lifetime stats sink (never this map or
        // the loop), so a counter that lands after this removal still adds.
        inflightProfiles.removeValue(forKey: requestId)
        if !hadRegisteredTask, modelId != nil {
            completedBeforeTaskRegistration.insert(requestId)
        }
        if let modelId {
            powerAssertion.release()
            modelSlots[modelId]?.lastInferenceAt = .now
            syncWarmModelState()
        }
        await updateAggregateCapacity()
    }

    /// Whether any inference work is still in flight — coordinator-routed
    /// (`inflightTasks`/`requestToModel`) OR local-endpoint streams
    /// (`localReservations`). Drain logic (shutdown + update hot-swap) waits on
    /// all three so a local stream is never cut off mid-generation.
    internal var hasInflightWork: Bool {
        !inflightTasks.isEmpty || !requestToModel.isEmpty || localReservations.hasAny
    }

    internal func waitForInflightDrain(timeout: Duration, reason: String = "shutdown") async -> Bool {
        guard hasInflightWork else { return true }
        logger.info("Waiting up to \(timeout.components.seconds)s for active inference to finish before \(reason)")
        let started = ContinuousClock.now
        while hasInflightWork {
            if Task.isCancelled { return false }
            if ContinuousClock.now - started >= timeout {
                return false
            }
            do {
                try await taskSleep( .milliseconds(250))
            } catch {
                return false
            }
        }
        return true
    }

}
