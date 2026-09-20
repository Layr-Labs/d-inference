/// ProviderLoop -- background prefetch + declarative desired-models reconcile.
///
/// Layer-3 background model prefetch (resume-aware), desired-build reconcile
/// with bounded-backoff retry, and post-verify advertise/hard-swap handling.

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
    // MARK: - Coordinator-driven background prefetch (Layer 3)

    /// Build the prefetch coordinator, wiring the pre-check (already
    /// loaded/on-disk?) and verified hook (add to advertised set + re-advertise)
    /// back into this actor. The live path uses the catalog/CDN-backed
    /// prefetcher; tests inject a fake coordinator via
    /// `installPrefetchCoordinatorForTesting`.
    internal func makePrefetchCoordinator() -> ModelPrefetchCoordinator {
        let me = self
        let prefetcher: any ModelPrefetcher =
            CatalogModelPrefetcher(
                coordinatorURL: loopConfig.coordinatorURL,
                runtimeCapabilities: loopConfig.runtimeCapabilities)
        return ModelPrefetchCoordinator(
            prefetcher: prefetcher,
            preCheck: { modelId in await me.prefetchPreCheck(modelId: modelId) },
            onVerified: { modelId in await me.applyVerifiedPrefetch(modelId: modelId) }
        )
    }

    /// Handle a coordinator `prefetch_model` request by delegating to the
    /// background prefetch coordinator. Non-blocking: returns as soon as the
    /// `.started` status is queued; the download runs on a low-priority task and
    /// never consumes a GPU slot or blocks inference.
    func handlePrefetchModelRequest(modelId: String, priority: Int, send: SendHandle) async {
        guard ModelRuntimeRequirements.isEligible(
            modelID: modelId, available: loopConfig.runtimeCapabilities)
        else {
            rejectPermanentlyIneligiblePrefetch(modelId: modelId, send: send)
            return
        }
        guard let prefetchCoordinator else {
            // Defensive: prefetchCoordinator is built in run() before the event
            // loop starts, so this should be unreachable on the live path.
            send.send(.prefetchModelStatus(
                modelId: modelId, status: .failed, bytesDone: 0, bytesTotal: 0,
                error: "prefetch subsystem not initialized"))
            return
        }
        if isShuttingDown {
            send.send(.prefetchModelStatus(
                modelId: modelId, status: .failed, bytesDone: 0, bytesTotal: 0,
                error: "provider is shutting down"))
            return
        }
        if isDrainingForUpdate {
            sendDrainingPrefetchFailure(modelId: modelId, send: send)
            return
        }
        logger.info("Prefetch request for \(modelId) (priority=\(priority))")
        // Failed terminal statuses feed the desired-build retry policy; for a
        // build that is not (or no longer) a desired target the notification is
        // a no-op (handleDesiredPrefetchFailure guards on the desired set).
        let sink = RetryNotifyingPrefetchSink(
            base: SendHandlePrefetchSink(send: send),
            onFailed: { [weak self] failedModelId, error in
                guard let self else { return }
                Task {
                    await self.handleDesiredPrefetchFailure(
                        modelId: failedModelId, error: error, send: send)
                }
            })
        await prefetchCoordinator.handlePrefetch(
            modelId: modelId,
            priority: priority,
            sink: sink
        )
    }

    /// React to a terminal `.failed` prefetch status for a build. Capability
    /// mismatches are permanent and clear desired/retry state. Other failures
    /// retain the bounded transient retry policy.
    private func handleDesiredPrefetchFailure(
        modelId: String, error: String?, send: SendHandle
    ) async {
        if error?.contains(ModelRuntimeIneligibleError.permanentFailureMarker) == true {
            desiredSwapDrop.removeValue(forKey: modelId)
            desiredPrefetchTargets.remove(modelId)
            staleDesiredPrefetches.insert(modelId)
            clearDesiredPrefetchRetryState(for: modelId)
            return
        }
        scheduleDesiredPrefetchRetry(modelId: modelId, send: send)
    }

    /// Schedule one bounded-backoff re-run of a desired build's prefetch.
    /// No-op when the build is no longer desired, a retry is already
    /// pending, or the delay budget is spent (until the next desired_models
    /// push resets it). Shared by the transient-failure path above and the
    /// reserve-floor refusal in `applyVerifiedPrefetch`: a build the box
    /// cannot take NOW may fit after an unload, and the coordinator
    /// deduplicates unchanged desired_models snapshots, so without a local
    /// retry the provider would sit on the superseded build indefinitely.
    private func scheduleDesiredPrefetchRetry(modelId: String, send: SendHandle) {
        guard !isShuttingDown,
              desiredPrefetchTargets.contains(modelId),
              !staleDesiredPrefetches.contains(modelId),
              desiredPrefetchRetryTasks[modelId] == nil
        else { return }
        let attempt = (desiredPrefetchRetryAttempts[modelId] ?? 0) + 1
        guard attempt <= desiredPrefetchRetryDelays.count else {
            logger.warning("Prefetch for desired build \(modelId) failed after \(attempt - 1) retries; giving up until the next desired_models push")
            return
        }
        desiredPrefetchRetryAttempts[modelId] = attempt
        let delay = desiredPrefetchRetryDelays[attempt - 1]
        logger.info("Scheduling desired-build prefetch retry \(attempt)/\(desiredPrefetchRetryDelays.count) for \(modelId) in \(delay)")
        desiredPrefetchRetryTasks[modelId] = Task { [weak self] in
            try? await taskSleep(delay)
            guard let self, !Task.isCancelled else { return }
            await self.retryDesiredPrefetch(modelId: modelId, send: send)
        }
    }

    /// A verified prefetch deferred for a capacity reason: remember it and
    /// schedule the bounded backoff. The remembered id is re-offered by the
    /// capacity-change events themselves (`retryReserveDeferredPrefetches`),
    /// because the backoff budget (~18 min) is shorter than the idle-unload
    /// horizon that typically frees the room.
    func deferPrefetchForCapacity(modelId: String) {
        // Remembered whether desired OR an explicit `prefetch_model`: the
        // coordinator ignores the `.verified` status this attempt still
        // emits, so a capacity-change re-offer is the only path that ever
        // advertises the build. The bounded backoff is desired-only (that
        // machinery is keyed on the desired set).
        reserveDeferredPrefetches.insert(modelId)
        guard desiredPrefetchTargets.contains(modelId), let send = outboundSend else { return }
        scheduleDesiredPrefetchRetry(modelId: modelId, send: send)
    }

    /// Re-offer every capacity-deferred build NOW. Called after a slot
    /// unloads and after a load finishes (installed or failed): both change
    /// the arithmetic the deferral was made under. Each id is forgotten
    /// BEFORE its re-run — a re-refusal re-remembers it through
    /// `deferPrefetchForCapacity`, an unscannable or no-longer-wanted build
    /// simply drops out. Desired builds also get a fresh backoff budget; a
    /// stale desired id is skipped. The re-run is a hash pass (the bytes are
    /// on disk) that re-enters `applyVerifiedPrefetch` and its preflight — a
    /// still-tight box defers again.
    internal func retryReserveDeferredPrefetches() async {
        guard !reserveDeferredPrefetches.isEmpty, !isShuttingDown, let send = outboundSend
        else { return }
        let deferred = reserveDeferredPrefetches.sorted()
        reserveDeferredPrefetches.removeAll()
        for modelId in deferred {
            if staleDesiredPrefetches.contains(modelId) { continue }
            // The refusing attempt may still be finishing inside the
            // coordinator (its terminal `.verified` emit follows the
            // onVerified await): a re-run now would COALESCE into it and
            // never reach applyVerifiedPrefetch again. Keep the deferral
            // (and the desired backoff) for the next capacity change.
            if await prefetchCoordinator?.isInFlight(modelId: modelId) == true {
                reserveDeferredPrefetches.insert(modelId)
                scheduleDeferredPrefetchWakeup(modelId: modelId)
                continue
            }
            if desiredPrefetchTargets.contains(modelId) {
                clearDesiredPrefetchRetryState(for: modelId)
            }
            logger.info("Re-offering capacity-deferred build \(modelId) after a capacity change")
            await handlePrefetchModelRequest(
                modelId: modelId, priority: Self.desiredModelsPrefetchPriority, send: send)
        }
    }

    /// A deferral was kept because its attempt was still finishing inside
    /// the coordinator when the capacity change fired. Explicit prefetches
    /// have no backoff timer, and the capacity-change callers may never
    /// fire again, so wait (off the actor) for the attempt's terminal
    /// cleanup and re-offer then. One wake-up per id; bounded by the
    /// attempt itself finishing.
    private func scheduleDeferredPrefetchWakeup(modelId: String) {
        guard deferredPrefetchWakeups[modelId] == nil else { return }
        deferredPrefetchWakeups[modelId] = Task { [weak self] in
            while let self, !Task.isCancelled,
                await self.prefetchCoordinator?.isInFlight(modelId: modelId) == true
            {
                try? await taskSleep(.milliseconds(250))
            }
            guard let self, !Task.isCancelled else { return }
            await self.finishDeferredPrefetchWakeup(modelId: modelId)
        }
    }

    private func finishDeferredPrefetchWakeup(modelId: String) async {
        deferredPrefetchWakeups.removeValue(forKey: modelId)
        guard reserveDeferredPrefetches.contains(modelId) else { return }
        await retryReserveDeferredPrefetches()
    }

    /// Fire a scheduled desired-build prefetch retry, re-checking that the
    /// build is still wanted (the desired set may have changed during the
    /// backoff sleep).
    private func retryDesiredPrefetch(modelId: String, send: SendHandle) async {
        desiredPrefetchRetryTasks.removeValue(forKey: modelId)
        guard !isShuttingDown,
              desiredPrefetchTargets.contains(modelId),
              !staleDesiredPrefetches.contains(modelId)
        else { return }
        logger.info("Retrying prefetch for desired build \(modelId)")
        await handlePrefetchModelRequest(modelId: modelId, priority: Self.desiredModelsPrefetchPriority, send: send)
    }

    /// Cancel and clear any scheduled prefetch retry for a build (used when the
    /// build leaves the desired set or a fresh desired_models push resets the
    /// retry budget).
    func clearDesiredPrefetchRetryState(for modelId: String) {
        desiredPrefetchRetryTasks.removeValue(forKey: modelId)?.cancel()
        desiredPrefetchRetryAttempts.removeValue(forKey: modelId)
    }
    private func rejectPermanentlyIneligiblePrefetch(
        modelId: String, send: SendHandle
    ) {
        desiredSwapDrop.removeValue(forKey: modelId)
        desiredPrefetchTargets.remove(modelId)
        staleDesiredPrefetches.insert(modelId)
        clearDesiredPrefetchRetryState(for: modelId)
        let eligibility = ModelRuntimeRequirements.evaluate(
            modelID: modelId, available: loopConfig.runtimeCapabilities)
        let message = ModelRuntimeIneligibleError(
            eligibility: eligibility).localizedDescription
        logger.error(message)
        send.send(.prefetchModelStatus(
            modelId: modelId,
            status: .failed,
            bytesDone: 0,
            bytesTotal: 0,
            error: message))
    }

    /// Pre-check used by the prefetch coordinator to short-circuit when a build
    /// is already available AND its integrity is already established. We only
    /// short-circuit when:
    ///   - the model is resident in a GPU slot (it loaded successfully, which
    ///     proves the on-disk build was usable), OR
    ///   - it is advertised with a known weight hash (verified at startup or by
    ///     a prior prefetch).
    ///
    /// A bare on-disk presence WITHOUT a recorded hash is deliberately treated
    /// as `.needsFetch`: the disk snapshot could be stale or corrupt, and
    /// `.verified` must mean "hash-checked". The prefetcher's resume path makes
    /// re-verifying an already-complete build cheap (skips valid files, only
    /// re-hashes), so we do not pay a full re-download for a good build — but we
    /// never report `.verified` for an unverified snapshot.
    internal func prefetchPreCheck(modelId: String) -> PrefetchPreCheck {
        if modelSlots[modelId] != nil { return .alreadyAvailable }
        if advertisedModels[modelId] != nil, modelHashes[modelId] != nil {
            return .alreadyAvailable
        }
        return .needsFetch
    }

    func applyVerifiedPrefetch(modelId: String) async {
        _ = await publishVerifiedPrefetch(modelId: modelId)
    }

    /// Locally retire a superseded build: stop advertising it (so no new requests
    /// route to it and the next register won't re-announce it) and forget its hash.
    /// The GPU slot, if resident, is left to the idle monitor — a lazy drop.
    func dropAdvertisedBuild(_ buildID: String) async {
        guard advertisedModels[buildID] != nil else { return }
        advertisedModels.removeValue(forKey: buildID)
        modelHashes.removeValue(forKey: buildID)
        await coordinatorClient?.unadvertiseModel(buildID)
        syncWarmModelState()
        // The shrunken set may carry a lower measured floor; let the runtime
        // KV budget relax to it. (Raising happened on the add side.) Then
        // regrow surviving engines — their grants were sized under the
        // dropped build's floor, and grant clamps are min(granted, current),
        // so nothing else would ever hand the difference back.
        await refreshActivationReserve()
        await resliceGrowSurvivors()
        await updateAggregateCapacity()
        logger.info("Hard swap: dropped superseded build \(buildID) from advertised set (\(advertisedModels.count) remaining)")
    }

    /// Reconcile the coordinator's declarative desired-state: for each public model
    /// name, converge to its desired build. Already-serving → ensure the previous
    /// build is dropped; missing → background-prefetch it (applyVerifiedPrefetch
    /// advertises it + drops the previous build once verified).
    internal func reconcileDesiredModels(_ entries: [CoordinatorMessage.DesiredModelEntry], send: SendHandle) async {
        let requestedDesired = Set(entries.map(\.desiredBuild).filter { !$0.isEmpty })
        let currentDesired = Set(requestedDesired.filter {
            ModelRuntimeRequirements.isEligible(
                modelID: $0, available: loopConfig.runtimeCapabilities)
        })
        for stale in desiredPrefetchTargets.subtracting(currentDesired) {
            desiredSwapDrop.removeValue(forKey: stale)
            staleDesiredPrefetches.insert(stale)
            clearDesiredPrefetchRetryState(for: stale)
        }
        desiredPrefetchTargets = currentDesired
        updateDesiredModelRevisions(entries)

        for entry in entries {
            let desired = entry.desiredBuild
            guard !desired.isEmpty else { continue }
            guard ModelRuntimeRequirements.isEligible(
                modelID: desired, available: loopConfig.runtimeCapabilities)
            else {
                rejectPermanentlyIneligiblePrefetch(modelId: desired, send: send)
                continue
            }
            staleDesiredPrefetches.remove(desired)
            // A fresh declarative push resets the retry budget (and supersedes
            // any pending backoff timer — the loop below re-prefetches a missing
            // desired build immediately).
            clearDesiredPrefetchRetryState(for: desired)
            let previous = (entry.previousBuild?.isEmpty == false) ? entry.previousBuild : nil
            if let previous, previous != desired {
                desiredSwapDrop[desired] = previous
            } else {
                desiredSwapDrop.removeValue(forKey: desired)
            }
            if entry.aggregateSHA256?.isEmpty == false, entry.revision?.isEmpty == false,
                !modelRevisionIsSelected(entry) || revisionUpdatesInProgress.contains(desired) {
                // The revision monitor stages without touching the selected
                // snapshot, then drains and activates. ID-only prefetch cannot
                // safely change the bytes beneath a resident engine.
                continue
            }
            // Already converged (advertised + verified) → ensure the old build is
            // no longer advertised locally AND re-emit the authoritative
            // models_update for the desired build. The coordinator derives the
            // previous-build drop from this update (against the alias's
            // desired/previous pair), so without it the coordinator would keep
            // routing the previous build to a provider that has locally stopped
            // advertising it — a state divergence. This matters when the desired
            // build was verified BEFORE a previous build was set on the alias (the
            // original verify carried no drop), and the swap is learned later.
            if let desiredInfo = advertisedModels[desired], modelHashes[desired] != nil {
                if let previous, advertisedModels[previous] != nil {
                    await dropAdvertisedBuild(previous)
                    // Authoritative re-announce so the coordinator drops previous too.
                    outboundSend?.send(.modelsUpdate(models: [desiredInfo]))
                }
                desiredSwapDrop.removeValue(forKey: desired)
                continue
            }
            logger.info("desired_models: \(entry.modelName) → converging to \(desired)")
            await handlePrefetchModelRequest(modelId: desired, priority: Self.desiredModelsPrefetchPriority, send: send)
        }
    }


}
