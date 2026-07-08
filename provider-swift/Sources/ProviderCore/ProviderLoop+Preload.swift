/// ProviderLoop -- coordinator-driven model preload (load_model push).
///
/// Handles `load_model` pushes that pre-warm a model out of band, tracks the
/// per-model preload tasks/subscribers, and the preload/shutdown wait helpers.

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
    // MARK: - Coordinator-driven preload

    /// Handle a `load_model` request from the coordinator. The provider
    /// kicks off the load asynchronously (so the WebSocket reader stays
    /// responsive) and emits `load_model_status` outbound messages
    /// reporting `started` immediately and `succeeded`/`failed` when the
    /// load completes.
    ///
    /// If the model is already loaded, we short-circuit with
    /// `succeeded` -- the coordinator can use this as an idempotent
    /// "ensure warm" call.
    internal func handleLoadModelRequest(modelId: String, send: SendHandle) {
        if isShuttingDown {
            send.send(.loadModelStatus(
                modelId: modelId,
                status: .failed,
                error: "provider is shutting down"
            ))
            return
        }
        if isDrainingForUpdate {
            sendDrainingLoadModelFailure(modelId: modelId, send: send)
            return
        }

        if modelSlots[modelId] != nil, !modelsUnloading.contains(modelId) {
            logger.info("Preload for \(modelId): already loaded, replying succeeded")
            send.send(.loadModelStatus(
                modelId: modelId,
                status: .succeeded,
                error: nil
            ))
            return
        }

        if preloadTasks[modelId] != nil {
            logger.info("Preload for \(modelId): already in progress, coalescing duplicate request")
            preloadStatusSubscribers[modelId, default: []].append(send)
            send.send(.loadModelStatus(
                modelId: modelId,
                status: .started,
                error: nil
            ))
            return
        }

        preloadStatusSubscribers[modelId] = [send]
        send.send(.loadModelStatus(
            modelId: modelId,
            status: .started,
            error: nil
        ))

        let me = self
        let taskId = UUID()
        preloadTaskIds[modelId] = taskId
        preloadTaskStarted?(modelId)
        preloadTasks[modelId] = Task {
            defer { Task { await me.removePreloadTask(modelId: modelId, taskId: taskId) } }
            do {
                try await me.ensureModelLoaded(modelId: modelId)
                try Task.checkCancellation()
                let shuttingDown = await me.isProviderShuttingDown()
                guard !shuttingDown else { return }
                await me.finishPreloadTask(modelId: modelId, taskId: taskId, status: .succeeded, error: nil)
            } catch is CancellationError {
                return
            } catch {
                let message = error.localizedDescription
                await me.logPreloadFailure(modelId: modelId, error: message)
                await me.finishPreloadTask(modelId: modelId, taskId: taskId, status: .failed, error: message)
            }
        }
    }

    private func finishPreloadTask(
        modelId: String,
        taskId: UUID,
        status: ProviderMessage.LoadModelStatus.Status,
        error: String?
    ) {
        guard preloadTaskIds[modelId] == taskId else { return }
        preloadTasks.removeValue(forKey: modelId)
        preloadTaskIds.removeValue(forKey: modelId)
        let subscribers = preloadStatusSubscribers.removeValue(forKey: modelId) ?? []
        for subscriber in subscribers {
            subscriber.send(.loadModelStatus(
                modelId: modelId,
                status: status,
                error: error
            ))
        }
    }

    internal func waitForPreloads(_ preloads: [Task<Void, Never>], timeout: Duration) async -> Bool {
        guard !preloads.isEmpty else { return true }
        return await withCheckedContinuation { continuation in
            let oneShot = OneShotBoolContinuation(continuation)

            Task {
                for task in preloads { await task.value }
                oneShot.resume(returning: true)
            }

            // Structured timeout: first resume wins (OneShotBoolContinuation
            // dedupes), so a slept Task replaces the GCD asyncAfter without
            // changing the race semantics.
            Task {
                try? await taskSleep( timeout)
                oneShot.resume(returning: false)
            }
        }
    }

    internal func cancelLoadWaiters() {
        for waiters in loadingWaiters.values {
            for waiter in waiters { waiter.resume(throwing: CancellationError()) }
        }
        loadingWaiters.removeAll()
        releaseLoadGateWaiters()
        for waiters in unloadingWaiters.values {
            for waiter in waiters { waiter.resume() }
        }
        unloadingWaiters.removeAll()
    }

    private func logPreloadFailure(modelId: String, error: String) {
        logger.error("Preload for \(modelId) failed: \(error)")
    }

    private func isProviderShuttingDown() -> Bool {
        isShuttingDown
    }

    /// Only remove the preload entry if it still belongs to this task,
    /// preventing a newer preload's entry from being removed by an older
    /// task's deferred cleanup.
    private func removePreloadTask(modelId: String, taskId: UUID) {
        if preloadTaskIds[modelId] == taskId {
            preloadTasks.removeValue(forKey: modelId)
            preloadTaskIds.removeValue(forKey: modelId)
            preloadStatusSubscribers.removeValue(forKey: modelId)
        }
    }

}
