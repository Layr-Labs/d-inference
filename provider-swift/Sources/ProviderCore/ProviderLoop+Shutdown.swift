/// ProviderLoop -- graceful-shutdown sequence.
///
/// The single, memoized shutdown path shared by the run-task cancellation
/// handler and the run-loop fall-through: drain in-flight inference while the
/// coordinator socket stays open (user stop/restart/schedule close), or cancel
/// promptly when the connection is already gone, then tear down the transport,
/// disk accountant, and loaded models.

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
    // MARK: - Graceful Shutdown

    /// Start (once) the graceful-shutdown sequence and return the shared task so
    /// every caller awaits the same drain + teardown. The first caller fixes
    /// `drainInflight`; later callers receive the in-progress task. This memo is
    /// what prevents the cancellation handler and the run-loop fall-through from
    /// running two competing shutdowns.
    ///
    /// The sequence runs in an unstructured `Task` that does NOT inherit the
    /// (cancelled) run task's cancellation, so `waitForInflightDrain` keeps
    /// polling instead of bailing on `Task.isCancelled`.
    @discardableResult
    internal func startShutdown(drainInflight: Bool) -> Task<Void, Never> {
        if let shutdownTask { return shutdownTask }
        let task = Task { await self.runShutdownSequence(drainInflight: drainInflight) }
        shutdownTask = task
        return task
    }

    /// The single graceful-shutdown sequence (runs exactly once via the
    /// `startShutdown` memo):
    ///   1. Mark `isShuttingDown` so new work is refused (503 reroute).
    ///   2. Either drain in-flight inference while keeping the coordinator socket
    ///      OPEN (so chunks + final completions still reach consumers), or — when
    ///      the connection is already gone — cancel in-flight work outright.
    ///   3. Only AFTER the drain completes, tear down the transport, the disk
    ///      accountant, and unload models, then release power assertions.
    private func runShutdownSequence(drainInflight: Bool) async {
        isShuttingDown = true
        if drainInflight {
            logger.info("Graceful shutdown requested; draining active inference before closing coordinator connection")
            // The run loop has stopped consuming coordinator events, but we keep
            // the socket open to finish in-flight responses. Tell the client to
            // reject NEW inference requests with 503 so the coordinator reroutes
            // them immediately instead of black-holing them for the whole drain,
            // and to route `cancel` frames for in-flight requests straight to
            // `handleCancellation` so an aborted stream stops generating promptly.
            // (A request yielded into the no-longer-consumed event stream in the
            // instant before `beginDraining` lands is neither processed nor
            // rejected here; the coordinator's first-chunk timeout + pre-content
            // retry recover it on another provider.)
            let drainSelf = self
            await coordinatorClient?.beginDraining(
                onCancel: { requestId in
                    await drainSelf.handleCancellation(requestId: requestId, receivedFromCoordinator: true)
                },
                onDisconnect: {
                    // The socket dropped mid-drain: the coordinator has failed our
                    // in-flight requests, so cancel them instead of generating
                    // frames that can no longer reach the consumer.
                    await drainSelf.cancelAllInflight()
                }
            )
            // Cancel background work + preloads first, but keep the coordinator
            // socket open so in-flight responses can still be delivered while we
            // drain. `sparingInflightLoads: true` lets a request that was still
            // cold-loading when shutdown began finish its load (only background
            // preloads are cancelled), so it can drain instead of erroring.
            await cancelBackgroundWorkAndPreloads(sparingInflightLoads: true)
            let drained = await waitForInflightDrain(timeout: Self.shutdownDrainTimeout)
            if !drained {
                logger.warning("Timed out waiting for active inference to drain; cancelling remaining requests")
                await cancelAllInflight()
                // The drain window is over: abort any loads that were spared above
                // but never finished, so suspended load tasks unwind.
                cancelLoadWaiters()
            }
            // Flush queued outbound frames (the tail of a finished request — its
            // last chunks and `inference_complete`) before tearing down the
            // transport, so a slow socket doesn't drop responses for a request
            // that just drained successfully.
            await coordinatorClient?.flushOutbound(timeout: Self.outboundFlushTimeout)
        } else {
            // The event stream ended without a controlled drain (e.g. coordinator
            // disconnect): the connection is already gone, so cancel in-flight
            // coordinator work rather than waiting on responses that can't be
            // delivered. Local-endpoint streams don't depend on the coordinator
            // connection — give them the same drain window the shutdown epilogue
            // always did before unloading models out from under them.
            await cancelAllInflight()
            await cancelBackgroundWorkAndPreloads(sparingInflightLoads: false)
            let drained = await waitForInflightDrain(timeout: Self.shutdownDrainTimeout)
            if !drained {
                logger.warning("Timed out waiting for local in-flight work to drain during shutdown")
            }
        }

        // Drain (if any) is complete: now it is safe to close the transport and
        // release GPU/model resources.
        await coordinatorClient?.shutdown()
        // Phase 3: shutdown the global disk accountant.
        await diskAccountant.shutdown()
        while !modelSlots.isEmpty {
            if let unloading = modelsUnloading.first {
                await waitForModelUnload(unloading)
                continue
            }
            for modelId in Array(modelSlots.keys) {
                await unloadModel(modelId)
            }
        }
        powerAssertion.releaseAll()
    }

    /// Cancel optional background tasks and prefetch/preload work. Idempotent so
    /// it can be called from both the drain and non-drain branches of
    /// `runShutdownSequence`. `sparingInflightLoads` is forwarded to
    /// `cancelLoadWaiters`: during a graceful drain we spare loads backing an
    /// accepted request so they can finish.
    private func cancelBackgroundWorkAndPreloads(sparingInflightLoads: Bool) async {
        idleMonitorTask?.cancel()
        idleMonitorTask = nil
        capacityRefreshTask?.cancel()
        capacityRefreshTask = nil
        autoUpdateTask?.cancel()
        autoUpdateTask = nil
        autoReportTask?.cancel()
        autoReportTask = nil
        // Cancel any scheduled desired-build prefetch retries before tearing
        // the prefetch subsystem down.
        for task in desiredPrefetchRetryTasks.values { task.cancel() }
        desiredPrefetchRetryTasks.removeAll()
        desiredPrefetchRetryAttempts.removeAll()
        // Cancel background prefetch downloads (no GPU slot, but they hold a
        // network connection and disk staging we want to release promptly).
        if let prefetchCoordinator {
            await prefetchCoordinator.shutdown(timeout: Self.preloadShutdownTimeout)
        }
        // During a graceful drain, a preload may be the actual loader for a model
        // that an already-accepted request is waiting on (the request sits in
        // `loadingWaiters` while the preload owns `ensureModelLoaded`). Cancelling
        // that preload would fail the accepted request instead of letting it
        // drain, so spare preloads whose model still backs an in-flight request
        // and only cancel/await the background-only ones. Spared preloads finish
        // the load (waiters resume) and clean themselves up via `removePreloadTask`.
        // The startup preload driver is always background work and is always
        // cancelled (its per-model loads are spared by `shutdownShouldAbortLoad`).
        let inflightModels = sparingInflightLoads ? Set(requestToModel.values) : Set<String>()
        let preloadsToCancel = preloadTasks.filter { !inflightModels.contains($0.key) }
        var cancelledPreloads = Array(preloadsToCancel.values)
        if let startupTask = startupPreloadTask {
            cancelledPreloads.append(startupTask)
        }
        for task in cancelledPreloads { task.cancel() }
        cancelLoadWaiters(sparingInflightRequests: sparingInflightLoads)
        let preloadsFinished = await waitForPreloads(cancelledPreloads, timeout: Self.preloadShutdownTimeout)
        if !preloadsFinished {
            logger.warning("Timed out waiting for coordinator-driven preloads to cancel during shutdown")
        }
        startupPreloadTask = nil
        for key in preloadsToCancel.keys {
            preloadTasks.removeValue(forKey: key)
            preloadTaskIds.removeValue(forKey: key)
            preloadStatusSubscribers.removeValue(forKey: key)
        }
    }

    /// During a graceful drain we still finish model loads that an
    /// already-accepted coordinator request is waiting on — its `modelId` is
    /// present in `requestToModel` (set, with `inference_accepted` already sent,
    /// in the same actor-atomic step before the load begins). Only pure
    /// background preloads (no in-flight request for the model) abort early. This
    /// lets `darkbloom stop`/`restart` drain a request that was still
    /// cold-loading when shutdown began instead of aborting it with an error.
    ///
    /// Local-endpoint requests are intentionally NOT spared: new local work is
    /// already refused on shutdown (`throwIfRefusingNewLocalWork`) both before
    /// and after the load, so sparing the load would only load a model the
    /// request is about to be rejected for.
    internal func shutdownShouldAbortLoad(_ modelId: String) -> Bool {
        isShuttingDown && !requestToModel.values.contains(modelId)
    }

}
