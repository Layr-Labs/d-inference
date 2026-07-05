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
        logger.info("Cancelling request: \(requestId)")
        let hadInflightTask = inflightTasks[requestId] != nil
        let hadModelReservation = requestToModel[requestId] != nil
        if receivedFromCoordinator && (hadInflightTask || hadModelReservation) {
            stats.incrementCancellationsReceived()
        }

        // P1 #1 (CRITICAL): do NOT call `scheduler.cancel(requestId:)`
        // directly here. After the MLXLMServer adoption,
        // `MultiModelBatchSchedulerEngine.streamChatCompletion` mints
        // a fresh internal request id when it calls
        // `BatchScheduler.submit(requestId:)`, so the coordinator-side
        // `requestId` we hold here does NOT match the id the scheduler
        // is tracking. A direct `scheduler.cancel(<coordinator id>)`
        // would be a no-op against an unknown id and let generation run
        // until on-termination tearing happens organically.
        //
        // Instead, rely on Task cancellation propagation:
        //
        //   ProviderLoop.task.cancel()
        //     -> `for try await frame in frames` raises CancellationError
        //     -> the detached task exits, the `frames` AsyncThrowingStream
        //        is deallocated, its `onTermination` fires
        //     -> MLXOpenAIService.streamChatCompletionFrames's inner
        //        task is cancelled, its iteration on the engine stream
        //        exits, the engine stream is deallocated, its
        //        `onTermination` fires
        //     -> MultiModelBatchSchedulerEngine.streamChatCompletion's
        //        `onTermination` calls
        //        `scheduler.cancel(<internal id>)` with the correct id.
        //
        // The cancellation-registry token below remains so the explicit
        // `if token.isCancelled` check inside the streaming loop also
        // fires on the next iteration (defense in depth — both paths
        // reach the same teardown).
        await cancellationRegistry.cancel(requestId: requestId)

        // ContinuousBatchingV2 (flag-gated, additive): forward the
        // coordinator request-id to any active v2 bridge so
        // `CBv2Engine.cancel` drops the row promptly (the in-flight step
        // completes, then the engine delivers `.finished(.cancelled)` and
        // the bridge tears down). Guarded on the slot set so the flag-off
        // steady state takes ZERO extra actor hops here. Defense in depth:
        // the primary v2 teardown is the same Task-cancellation propagation
        // documented above (the bridge stream's onTermination cancels the
        // engine-minted id); this fan-out additionally catches any submit
        // made directly under the coordinator id.
        if hasEngineV2Slots {
            await engineV2Runtime.cancel(requestId: requestId)
        }

        if requestToModel.removeValue(forKey: requestId) != nil {
            if !hadInflightTask {
                stats.incrementCancelDuringModelLoad()
            }
            powerAssertion.release()
        }

        syncWarmModelState()
        await updateAggregateCapacity()

        // Cancel the detached cold-load task (if this request is still loading),
        // so `handleInferenceRequest`'s `await loadTask.value` unblocks. Without
        // this, a cancel during a stalled cold load would leave the serve task
        // awaiting forever and the CLI would escalate to SIGKILL.
        if let loadTask = inflightModelLoadTasks.removeValue(forKey: requestId) {
            loadTask.cancel()
        }

        if let task = inflightTasks.removeValue(forKey: requestId) {
            task.cancel()
        }
    }

    internal func cancelAllInflight() async {
        // Cancel detached model-load tasks first: a request still cold-loading
        // (awaiting `loadTask.value` in `handleInferenceRequest`) only unblocks
        // when its load task is cancelled or finishes. Without this, a stalled
        // load would keep `run()` from returning past the drain timeout.
        for task in inflightModelLoadTasks.values { task.cancel() }
        inflightModelLoadTasks.removeAll()
        let requestIds = Array(inflightTasks.keys)
        for requestId in requestIds {
            await handleCancellation(requestId: requestId, receivedFromCoordinator: false)
        }
        inflightTasks.removeAll()
        completedBeforeTaskRegistration.removeAll()
        if !requestToModel.isEmpty {
            powerAssertion.releaseAll()
        }
        requestToModel.removeAll()
        syncWarmModelState()
    }

    internal func finishInflightRequest(requestId: String) async {
        let hadRegisteredTask = inflightTasks.removeValue(forKey: requestId) != nil
        let modelId = requestToModel.removeValue(forKey: requestId)
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

    internal func waitForInflightDrain(timeout: Duration) async -> Bool {
        guard hasInflightWork else { return true }
        logger.info("Waiting up to \(timeout.components.seconds)s for active inference to finish before shutdown")
        let started = ContinuousClock.now
        while hasInflightWork {
            // During a controlled shutdown (user stop/restart, schedule window
            // close, or update hot-swap) we want to finish active inference even
            // if the outer task was cancelled. Only abort early on cancellation
            // when we are not in the shutdown path.
            if !isShuttingDown, Task.isCancelled { return false }
            if ContinuousClock.now - started >= timeout {
                return false
            }
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                if !isShuttingDown { return false }
                // Controlled shutdown: ignore cancellation from the sleep and
                // keep polling until the work finishes or the timeout expires.
            }
        }
        return true
    }

}
