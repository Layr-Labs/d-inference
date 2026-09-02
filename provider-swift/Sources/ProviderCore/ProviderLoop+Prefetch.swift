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
    /// True when the durable failed-self-test record refuses this (id, hash)
    /// pair: same bytes that failed, or the "" sentinel (bytes unknown —
    /// refuse every same-id build until restart). Checked at EVERY guard in
    /// `applyVerifiedPrefetch`, not just the first: a retirement completing
    /// entirely inside any of the suspensions sets the record after an
    /// earlier check already passed.
    private func selfTestRecordRefuses(modelId: String, hash: String) -> Bool {
        guard let failed = failedSelfTestHashes[modelId] else { return false }
        return failed.isEmpty || failed == hash
    }

    func applyVerifiedPrefetch(modelId: String) async {
        guard ModelRuntimeRequirements.isEligible(
            modelID: modelId, available: loopConfig.runtimeCapabilities)
        else {
            desiredSwapDrop.removeValue(forKey: modelId)
            desiredPrefetchTargets.remove(modelId)
            staleDesiredPrefetches.insert(modelId)
            clearDesiredPrefetchRetryState(for: modelId)
            logger.error(
                "Ignoring verified prefetch for permanently ineligible model \(modelId)")
            return
        }
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
        // Fail-closed against the self-test verdict, ABA-proof: the
        // detached scan/hash above can span an ENTIRE retirement (insert
        // AND removal of its tombstone), so the tombstone checks below
        // cannot catch that interleaving alone. The failed-hash record
        // persists: the same bytes that failed the self-test are refused
        // here no matter how the suspensions interleave; different bytes
        // are a genuinely new build and clear the record.
        guard !selfTestRecordRefuses(modelId: modelId, hash: hash) else {
            desiredSwapDrop.removeValue(forKey: modelId)
            logger.warning(
                "Prefetch verified \(modelId) but this build "
                    + "(weight_hash=\(hash.prefix(16))) is refused by the failed "
                    + "self-test record; not re-advertising")
            return
        }
        // A different-hash build clears the record only at the ADVERTISE
        // point below, not here: a verify that passes this check but is
        // then refused by a later guard must leave the record standing, or
        // an operator byte-rollback afterwards would sneak the failed build
        // past a fresh verify.
        // Architecture-derived supported set (v0.7.5): a prefetched build
        // whose family has no CBv2 adapter can never serve — advertising it
        // would invite requests that always refuse. Keep the previous build
        // serving; the catalog entry is the thing that needs fixing.
        guard EngineV2SupportedModels.isSupported(modelType: info.modelType) else {
            desiredSwapDrop.removeValue(forKey: modelId)
            logger.error(
                "Prefetch verified \(modelId) but model_type '\(info.modelType ?? "unknown")' "
                    + "has no CBv2 adapter (v0.7.5 serves everything through engine v2); "
                    + "not advertising (keeping the previous build)")
            return
        }
        // Adding to `advertisedModels` also raises the effective slot cap
        // (`maxModelSlots` is computed from this set), so the newly-verified
        // build can be held resident alongside the model currently being served
        // during a zero-downtime migration -- bounded by the configured hard
        // cap (`configuredMaxModelSlots`).
        // A tombstoned id is mid-retirement (failed self-test, unload
        // draining): its resident slot makes prefetchPreCheck report
        // `.alreadyAvailable`, and re-advertising here would undo the
        // fail-closed removal — the retired build must stay dark until the
        // retirement completes and a FUTURE prefetch re-verifies it.
        guard !retiringModels.contains(modelId) else {
            logger.warning(
                "Prefetch verified \(modelId) but it is mid-retirement; not re-advertising")
            return
        }
        // Raise the runtime KV reserve for the grown serving set BEFORE the
        // build joins `advertisedModels` (and so before it is announced or
        // loadable) — a decode step of the new model must never run against a
        // reserve resolved without it. Epoch-stamped, so a concurrent
        // refresh's stale value cannot land after this one.
        // Held from the preflight through the re-slice + capacity publish,
        // exactly as a load holds it across its own preflight-through-
        // install: a load admitted in between would size its slot against
        // the pre-raise budget and be shrunk below the floor by the
        // re-slice below with neither side having seen the other. Released
        // explicitly at every exit (the load path's idiom).
        await acquireResliceGate()
        let raisedReserve = UnifiedMemoryCap.resolvedActivationReserveBytes(
            modelIDs: Array(advertisedModels.keys) + Array(modelSlots.keys)
                + Array(modelsLoading) + [modelId])
        // The raise shrinks the fleet KV budget the RESIDENT slots share;
        // on a tight multi-slot box it can push a survivor below the
        // serviceable minimum with no new slot loaded. Refuse the
        // advertisement before touching anything — the same floor the load
        // path refuses a newcomer on. No durable record: the next desired-
        // state reconcile may re-offer the build (a verify pass, no
        // download) against a fleet that may have room by then.
        guard await reserveRaiseKeepsSurvivorsServiceable(reserveBytes: raisedReserve) else {
            releaseResliceGate()
            logger.warning(
                "Prefetch verified \(modelId) but its activation floor would re-slice a resident "
                    + "model's KV grant below the serviceability floor; not advertising")
            return
        }
        await pushActivationReserve(raisedReserve)
        // Re-check the tombstone AND the durable record AFTER the push's
        // suspension: a retirement can run — or fully complete — during
        // that await; the tombstone catches an in-progress one and the
        // record catches a completed one. (The pushed raise is harmless —
        // epoch-ordered; retirement's own refresh carries a newer epoch.)
        guard !retiringModels.contains(modelId),
            !selfTestRecordRefuses(modelId: modelId, hash: hash)
        else {
            // The pre-insert push above already raised the budget for an id
            // that will now never join the set — recompute without it, or
            // the phantom raise stands until the next unrelated mutation.
            await refreshActivationReserve()
            releaseResliceGate()
            logger.warning(
                "Prefetch verified \(modelId) but retirement began during the reserve push; not advertising")
            return
        }
        // A different-hash build reaching the actual advertise clears the
        // failed-self-test record (same-hash builds were refused above; the
        // clear deliberately does NOT happen at the check, see there).
        failedSelfTestHashes.removeValue(forKey: modelId)
        advertisedModels[modelId] = info
        modelHashes[modelId] = hash
        liveModelHashes[modelId] = hash
        syncWarmModelState()
        // Re-refresh AFTER the insert too: a concurrent refresh (idle unload,
        // retire) interleaving in the pre-insert await computed WITHOUT the
        // incoming id and could land last — this post-insert refresh, now
        // resolving over the set that includes it, makes the final value
        // authoritative either way (the pre-insert push handles raise-early,
        // this one handles lost-update).
        await refreshActivationReserve()
        // The raise shrinks the fleet KV budget: re-slice the resident
        // engines' grants against it and refresh the aggregate capacity
        // BEFORE announcing the enlarged set, or the coordinator routes
        // against a token budget the tightened shared KV gate rejects until
        // the next periodic capacity tick.
        await resliceGrowSurvivorsLocked()
        await updateAggregateCapacity()
        releaseResliceGate()
        // Final re-check before announcing to the coordinator: retirement
        // interleaving in the refresh suspension above removes the local
        // advertisement — announcing then would diverge the client store
        // from the loop's (the fail-closed removal must win).
        guard !retiringModels.contains(modelId),
            !selfTestRecordRefuses(modelId: modelId, hash: hash),
            advertisedModels[modelId] != nil
        else {
            logger.warning(
                "Prefetch verified \(modelId) but retirement removed it before announcement; not advertising")
            return
        }
        logger.info("Prefetch verified \(modelId) (weight_hash=\(hash.prefix(16))); advertising (\(advertisedModels.count) model(s) total)")
        if let coordinatorClient {
            await coordinatorClient.updateModelWeightHashes(liveModelHashes)
            await coordinatorClient.advertiseModel(info)
            // Retirement interleaving in the two client awaits above removes
            // the LOCAL advertisement; the client add we just made would then
            // be the only copy — and the retirement's post-drain reconnect
            // would register a build the loop no longer serves (persistent
            // false routing). Undo the client add and skip the live
            // announcement. No suspension sits between this check and the
            // sync `outboundSend` below, so the announcement cannot race
            // past it.
            guard advertisedModels[modelId] != nil, !retiringModels.contains(modelId)
            else {
                await coordinatorClient.unadvertiseModel(modelId)
                // The store rollback cannot retract a registration the
                // reconnect loop already encoded from the transiently-stale
                // store (retirement's own reconnect can fire while we sat in
                // the client awaits above). Force one more reconnect so the
                // coordinator's registered inventory converges on the
                // corrected store — rare double-race path; the disruption is
                // bounded and correctness-restoring.
                await coordinatorClient.forceReconnect()
                logger.warning(
                    "Prefetch announcement for \(modelId) aborted: retirement removed it "
                        + "mid-announce; client store restored and re-registered")
                return
            }
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
