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

        // MLXLMServer mints an internal request id before submitting to the
        // EngineV2 bridge, so the coordinator id held here may not match the
        // id the engine tracks. Cancelling only by coordinator id can therefore
        // be a no-op.
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
        //        `onTermination` cancels the bridge's internal id.
        //
        // The cancellation-registry token below remains so the explicit
        // `if token.isCancelled` check inside the streaming loop also
        // fires on the next iteration (defense in depth — both paths
        // reach the same teardown).
        await cancellationRegistry.cancel(requestId: requestId)

        // Forward the coordinator request-id to the owning EngineV2 bridge so
        // `CBv2Engine.cancel` drops the row promptly (the in-flight step
        // completes, then the engine delivers `.finished(.cancelled)` and
        // the bridge tears down). The zero-slot guard avoids an actor hop.
        // Defense in depth:
        // the primary v2 teardown is the same Task-cancellation propagation
        // documented above (the bridge stream's onTermination cancels the
        // engine-minted id); this fan-out additionally catches any submit
        // made directly under the coordinator id.
        if hasEngineV2Slots {
            await engineV2Runtime.cancel(requestId: requestId)
        }

        if requestToModel.removeValue(forKey: requestId) != nil {
            InferenceActivityTracker.shared.end(requestId)
            if !hadInflightTask {
                stats.incrementCancelDuringModelLoad()
            }
            powerAssertion.release()
        }

        syncWarmModelState()
        await updateAggregateCapacity()

        if let task = inflightTasks.removeValue(forKey: requestId) {
            task.cancel()
        }
    }

    internal func cancelAllInflight() async {
        let requestIds = Array(inflightTasks.keys)
        for requestId in requestIds {
            await handleCancellation(requestId: requestId, receivedFromCoordinator: false)
        }
        inflightTasks.removeAll()
        completedBeforeTaskRegistration.removeAll()
        if !requestToModel.isEmpty {
            powerAssertion.releaseAll()
        }
        for requestId in requestToModel.keys {
            InferenceActivityTracker.shared.end(requestId)
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
        InferenceActivityTracker.shared.end(requestId)
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
