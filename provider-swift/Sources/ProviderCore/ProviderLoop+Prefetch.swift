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
            CatalogModelPrefetcher(coordinatorURL: loopConfig.coordinatorURL)
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
            onFailed: { [weak self] failedModelId in
                guard let self else { return }
                Task { await self.handleDesiredPrefetchFailure(modelId: failedModelId, send: send) }
            }
        )
        await prefetchCoordinator.handlePrefetch(
            modelId: modelId,
            priority: priority,
            sink: sink
        )
    }

    /// React to a terminal `.failed` prefetch status for a build. If the build
    /// is still a desired target (and not stale), schedule a single
    /// bounded-backoff retry — the resume-aware downloader continues from the
    /// bytes already on disk, so retries are cheap. After the delay budget is
    /// exhausted the provider stays on its current build until the next
    /// desired_models push (operator re-POST or reconnect), which resets the
    /// budget and retries immediately via reconcile.
    private func handleDesiredPrefetchFailure(modelId: String, send: SendHandle) async {
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
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            await self.retryDesiredPrefetch(modelId: modelId, send: send)
        }
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
    private func clearDesiredPrefetchRetryState(for modelId: String) {
        desiredPrefetchRetryTasks.removeValue(forKey: modelId)?.cancel()
        desiredPrefetchRetryAttempts.removeValue(forKey: modelId)
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

    /// Re-advertise hook fired on `.verified`. Adds the newly-available build to
    /// the in-memory advertised set (so it is loadable/servable and appears in
    /// the local `/v1/models` catalog), records its weight hash (so attestation
    /// covers the hotswapped model), and registers it with the coordinator's
    /// advertised inventory. The currently-served model is never removed, so
    /// both old and new are advertised during the transition.
    ///
    /// The scan + weight-hash computation run OFF the actor (`Task.detached`,
    /// utility priority) so hashing a multi-GB build never blocks inference or
    /// the event loop; only the small dictionary writes happen on the actor.
    func applyVerifiedPrefetch(modelId: String) async {
        if staleDesiredPrefetches.remove(modelId) != nil {
            desiredSwapDrop.removeValue(forKey: modelId)
            logger.info("Ignoring verified prefetch for stale desired build \(modelId); alias target changed before verification completed")
            return
        }

        // Compute ModelInfo + weight hash off-actor (CPU/IO heavy for big
        // builds). The prefetcher already aggregate-verified the snapshot, so
        // this hash is over a known-good build. Returns nil if the on-disk
        // snapshot cannot be resolved/scanned.
        let computed = await Task.detached(priority: .utility) { () -> (ModelInfo, String?)? in
            guard let info = Self.scanVerifiedModelInfo(modelId: modelId) else { return nil }
            let hash = WeightHasher.computeHash(for: modelId)
            var withHash = info
            withHash.weightHash = hash
            return (withHash, hash)
        }.value

        // A verified prefetch whose snapshot we can't scan must NOT be
        // advertised: a synthetic zero-size ModelInfo would be routed with
        // estimatedMemoryGb == 0, bypassing memory sizing/admission until the
        // real load overcommits. Drop it instead — without a models_update the
        // coordinator simply never routes this build here, which is the safe outcome.
        guard let (info, maybeHash) = computed else {
            desiredSwapDrop.removeValue(forKey: modelId)
            logger.error("Prefetch verified \(modelId) but its on-disk snapshot could not be scanned; not advertising (would bypass memory sizing)")
            return
        }
        // A nil weight hash is treated exactly like an unscannable snapshot: do
        // NOT advertise, emit, or hard-swap. The coordinator's models_update
        // gate REQUIRES a non-empty matching hash when the catalog pins one, so a
        // hashless advertise would be rejected there anyway — but worse, dropping
        // the previous build here while the coordinator rejects the desired one
        // would strand the provider on neither build. Keep the previous build
        // serving; the prefetch can be retried.
        guard let hash = maybeHash, !hash.isEmpty else {
            desiredSwapDrop.removeValue(forKey: modelId)
            logger.error("Prefetch verified \(modelId) but the weight hash could not be computed; not advertising (keeping the previous build to avoid an unverifiable swap)")
            return
        }
        // Adding to `advertisedModels` also raises the effective slot cap
        // (`maxModelSlots` is computed from this set), so the newly-verified
        // build can be held resident alongside the model currently being served
        // during a zero-downtime migration -- bounded by the configured hard
        // cap (`configuredMaxModelSlots`).
        advertisedModels[modelId] = info
        modelHashes[modelId] = hash
        syncWarmModelState()
        logger.info("Prefetch verified \(modelId) (weight_hash=\(hash.prefix(16))); advertising (\(advertisedModels.count) model(s) total)")
        if let coordinatorClient {
            await coordinatorClient.advertiseModel(info)
        }
        // Push the authoritative ModelInfo (incl. the just-computed weight hash)
        // to the coordinator out-of-band so it can cross-check the build against
        // the catalog before routing -- without waiting for a reconnect's
        // `register`, and without the disruption of re-registering. The local
        // `advertiseModel` above still carries the union on the next reconnect.
        outboundSend?.send(.modelsUpdate(models: [info]))

        // Hard swap: the desired build is now advertised + announced, so drop the
        // build it supersedes from our LOCAL advertised set — we stop serving it and
        // it idle-unloads. The models_update above already makes the coordinator stop
        // routing the previous build here (it derives the drop from the alias's
        // desired/previous pair). We do NOT force-unload a resident slot; the idle
        // monitor reclaims it.
        if let previous = desiredSwapDrop.removeValue(forKey: modelId), previous != modelId {
            await dropAdvertisedBuild(previous)
        }
    }

    /// Locally retire a superseded build: stop advertising it (so no new requests
    /// route to it and the next register won't re-announce it) and forget its hash.
    /// The GPU slot, if resident, is left to the idle monitor — a lazy drop.
    private func dropAdvertisedBuild(_ buildID: String) async {
        guard advertisedModels[buildID] != nil else { return }
        advertisedModels.removeValue(forKey: buildID)
        modelHashes.removeValue(forKey: buildID)
        await coordinatorClient?.unadvertiseModel(buildID)
        syncWarmModelState()
        logger.info("Hard swap: dropped superseded build \(buildID) from advertised set (\(advertisedModels.count) remaining)")
    }

    /// Reconcile the coordinator's declarative desired-state: for each public model
    /// name, converge to its desired build. Already-serving → ensure the previous
    /// build is dropped; missing → background-prefetch it (applyVerifiedPrefetch
    /// advertises it + drops the previous build once verified).
    internal func reconcileDesiredModels(_ entries: [CoordinatorMessage.DesiredModelEntry], send: SendHandle) async {
        let currentDesired = Set(entries.map(\.desiredBuild).filter { !$0.isEmpty })
        for stale in desiredPrefetchTargets.subtracting(currentDesired) {
            desiredSwapDrop.removeValue(forKey: stale)
            staleDesiredPrefetches.insert(stale)
            clearDesiredPrefetchRetryState(for: stale)
        }
        desiredPrefetchTargets = currentDesired

        for entry in entries {
            let desired = entry.desiredBuild
            guard !desired.isEmpty else { continue }
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

    /// Scan the on-disk snapshot for a freshly-prefetched model to produce an
    /// advertised `ModelInfo` (type, quantization, size, memory estimate).
    /// Static + nonisolated so it can run inside the off-actor hashing task.
    private static func scanVerifiedModelInfo(modelId: String) -> ModelInfo? {
        guard let snapshot = ModelScanner.resolveLocalPath(modelID: modelId) else { return nil }
        return ModelScanner.parseModelInfo(snapshotDir: snapshot, modelName: modelId)
    }

}
