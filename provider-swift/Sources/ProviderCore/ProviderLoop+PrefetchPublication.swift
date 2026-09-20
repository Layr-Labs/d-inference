import Foundation

extension ProviderLoop {
    private func publicationIsCurrent(_ revision: CoordinatorMessage.DesiredModelEntry?) -> Bool {
        guard let revision else { return true }
        return !Task.isCancelled && revisionIsDesired(revision)
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

    func publishVerifiedPrefetch(modelId: String,
                                 expectedRevision: CoordinatorMessage.DesiredModelEntry? = nil,
                                 verifiedArtifact: (ModelInfo, String)? = nil) async -> Bool {
        guard publicationIsCurrent(expectedRevision) else { return false }
        if revisionUpdatesInProgress.contains(modelId), expectedRevision == nil { return false }
        // A revision drain cannot pass an older advertisement suspended in
        // hashing, memory re-slicing or the coordinator client. Once the drain
        // begins, this entry guard prevents any new ID-only publication.
        prefetchPublicationCounts[modelId, default: 0] += 1
        defer {
            prefetchPublicationCounts[modelId, default: 1] -= 1
            if prefetchPublicationCounts[modelId] == 0 { prefetchPublicationCounts.removeValue(forKey: modelId) }
        }
        guard ModelRuntimeRequirements.isEligible(
            modelID: modelId, available: loopConfig.runtimeCapabilities)
        else {
            desiredSwapDrop.removeValue(forKey: modelId)
            desiredPrefetchTargets.remove(modelId)
            staleDesiredPrefetches.insert(modelId)
            clearDesiredPrefetchRetryState(for: modelId)
            logger.error(
                "Ignoring verified prefetch for permanently ineligible model \(modelId)")
            return false
        }
        if staleDesiredPrefetches.remove(modelId) != nil {
            desiredSwapDrop.removeValue(forKey: modelId)
            logger.info("Ignoring verified prefetch for stale desired build \(modelId); alias target changed before verification completed")
            return false
        }

        // Compute ModelInfo + weight hash off-actor (CPU/IO heavy for big
        // builds). The prefetcher already aggregate-verified the snapshot, so
        // this hash is over a known-good build. Returns nil if the on-disk
        // snapshot cannot be resolved/scanned.
        let computed: (ModelInfo, String?)?
        if let verifiedArtifact {
            computed = (verifiedArtifact.0, verifiedArtifact.1)
        } else {
            computed = await Task.detached(priority: .utility) { () -> (ModelInfo, String?)? in
                guard let info = Self.scanVerifiedModelInfo(modelId: modelId) else { return nil }
                let hash = WeightHasher.computeHash(for: modelId)
                var withHash = info
                withHash.weightHash = hash
                return (withHash, hash)
            }.value
        }

        guard publicationIsCurrent(expectedRevision) else { return false }

        // A verified prefetch whose snapshot we can't scan must NOT be
        // advertised: a synthetic zero-size ModelInfo would be routed with
        // estimatedMemoryGb == 0, bypassing memory sizing/admission until the
        // real load overcommits. Drop it instead — without a models_update the
        // coordinator simply never routes this build here, which is the safe outcome.
        guard let (info, maybeHash) = computed else {
            desiredSwapDrop.removeValue(forKey: modelId)
            logger.error("Prefetch verified \(modelId) but its on-disk snapshot could not be scanned; not advertising (would bypass memory sizing)")
            return false
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
            return false
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
            return false
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
        guard EngineV2SupportedModels.isSupported(model: info) else {
            desiredSwapDrop.removeValue(forKey: modelId)
            logger.error(
                "Prefetch verified \(modelId) but model_type '\(info.modelType ?? "unknown")' "
                    + "has no CBv2 adapter (v0.7.5 serves everything through engine v2); "
                    + "not advertising (keeping the previous build)")
            return false
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
            return false
        }
        // Raise the runtime KV reserve for the grown serving set BEFORE the
        // build joins `advertisedModels` (and so before it is announced or
        // loadable) — a decode step of the new model must never run against a
        // reserve resolved without it. Epoch-stamped, so a concurrent
        // refresh's stale value cannot land after this one.
        // Serialize behind in-flight loads: a load between its admission
        // gate and slot install (`modelsLoading`, set before the gate) was
        // admitted against the CURRENT floor, and raising it underneath
        // would overcommit the load transient before the post-load guard
        // can act — the pending-load reservation fences competing KV
        // grants, not this. Defer through the desired-build backoff; the
        // load's install clears the marker well within the retry budget.
        guard modelsLoading.isEmpty else {
            logger.info(
                "Prefetch verified \(modelId) while a load is in flight (\(modelsLoading.sorted())); "
                    + "deferring the advertisement")
            deferPrefetchForCapacity(modelId: modelId)
            return false
        }
        // Held from the preflight through the re-slice + capacity publish,
        // exactly as a load holds it across its own preflight-through-
        // install: a load admitted in between would size its slot against
        // the pre-raise budget and be shrunk below the floor by the
        // re-slice below with neither side having seen the other. Released
        // explicitly at every exit (the load path's idiom).
        await acquireResliceGate()
        guard publicationIsCurrent(expectedRevision) else {
            releaseResliceGate()
            return false
        }
        let raisedReserve = UnifiedMemoryCap.resolvedActivationReserveBytes(
            modelIDs: Array(advertisedModels.keys) + Array(modelSlots.keys)
                + Array(modelsLoading) + [modelId])
        // The raise shrinks the fleet KV budget the RESIDENT slots share;
        // on a tight multi-slot box it can push a survivor below the
        // serviceable minimum with no new slot loaded. Refuse the
        // advertisement before touching anything — the same floor the load
        // path refuses a newcomer on. Then retry through the desired-build
        // backoff policy (the re-run is a hash pass — the bytes are on
        // disk): `.verified` still goes out for this attempt and the
        // coordinator deduplicates unchanged desired_models pushes, so
        // without a local retry nothing would ever re-offer the build,
        // even after an unload frees the room.
        let keepsSurvivors = await reserveRaiseKeepsSurvivorsServiceable(reserveBytes: raisedReserve)
        guard publicationIsCurrent(expectedRevision) else {
            releaseResliceGate()
            return false
        }
        guard keepsSurvivors else {
            releaseResliceGate()
            logger.warning(
                "Prefetch verified \(modelId) but its activation floor would re-slice a resident "
                    + "model's KV grant below the serviceability floor; not advertising")
            deferPrefetchForCapacity(modelId: modelId)
            return false
        }
        // Re-check in-flight loads AFTER the preflight (it awaited each
        // bridge's grant): a load admitted during those hops passed its gate
        // against the pre-raise floor and is not in `modelSlots` yet, so the
        // preflight neither counted its weights nor covered its transient.
        guard modelsLoading.isEmpty else {
            releaseResliceGate()
            logger.info(
                "Prefetch verified \(modelId) but a load entered during the preflight; "
                    + "deferring the advertisement")
            deferPrefetchForCapacity(modelId: modelId)
            return false
        }
        // Pin the id into the live reserve basis BEFORE the push's own
        // suspension: a load admitted during the push then resolves its gate
        // and fleet budget against the raised floor already (the basis is
        // advertised ∪ resident ∪ loading ∪ pending-advertise). Removed the
        // moment the id joins `advertisedModels`, or on the refusal below.
        pendingAdvertise.insert(modelId)
        await pushActivationReserve(raisedReserve)
        // Re-check the tombstone AND the durable record AFTER the push's
        // suspension: a retirement can run — or fully complete — during
        // that await; the tombstone catches an in-progress one and the
        // record catches a completed one. (The pushed raise is harmless —
        // epoch-ordered; retirement's own refresh carries a newer epoch.)
        guard publicationIsCurrent(expectedRevision), !retiringModels.contains(modelId),
            !selfTestRecordRefuses(modelId: modelId, hash: hash)
        else {
            // The pre-insert push above already raised the budget for an id
            // that will now never join the set — recompute without it, or
            // the phantom raise stands until the next unrelated mutation.
            pendingAdvertise.remove(modelId)
            await refreshActivationReserve()
            releaseResliceGate()
            logger.warning(
                "Prefetch verified \(modelId) but retirement or a superseding revision invalidated the reserve push; not advertising")
            return false
        }
        // A different-hash build reaching the actual advertise clears the
        // failed-self-test record (same-hash builds were refused above; the
        // clear deliberately does NOT happen at the check, see there).
        failedSelfTestHashes.removeValue(forKey: modelId)
        advertisedModels[modelId] = info
        pendingAdvertise.remove(modelId)  // now carried by `advertisedModels`
        reserveDeferredPrefetches.remove(modelId)  // the capacity deferral is over
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
        guard publicationIsCurrent(expectedRevision) else {
            releaseResliceGate()
            return false // Revision activation owns rollback of the provisional advertisement.
        }
        // The raise shrinks the fleet KV budget: re-slice the resident
        // engines' grants against it and refresh the aggregate capacity
        // BEFORE announcing the enlarged set, or the coordinator routes
        // against a token budget the tightened shared KV gate rejects until
        // the next periodic capacity tick.
        await resliceGrowSurvivorsLocked()
        guard publicationIsCurrent(expectedRevision) else {
            releaseResliceGate()
            return false
        }
        await updateAggregateCapacity()
        releaseResliceGate()
        // Final re-check before announcing to the coordinator: retirement
        // interleaving in the refresh suspension above removes the local
        // advertisement — announcing then would diverge the client store
        // from the loop's (the fail-closed removal must win).
        guard publicationIsCurrent(expectedRevision), !retiringModels.contains(modelId),
            !selfTestRecordRefuses(modelId: modelId, hash: hash),
            advertisedModels[modelId] != nil
        else {
            logger.warning(
                "Prefetch verified \(modelId) but retirement removed it before announcement; not advertising")
            return false
        }
        logger.info("Prefetch verified \(modelId) (weight_hash=\(hash.prefix(16))); advertising (\(advertisedModels.count) model(s) total)")
        if let coordinatorClient {
            await coordinatorClient.updateModelWeightHashes(liveModelHashes)
            guard publicationIsCurrent(expectedRevision) else { return false }
            await coordinatorClient.advertiseModel(info)
            guard publicationIsCurrent(expectedRevision) else { return false }
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
                return false
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
        // Revision activation consumes lineage only after this publication
        // returns and its caller rechecks cancellation and desired identity.
        if expectedRevision == nil,
            let previous = desiredSwapDrop.removeValue(forKey: modelId), previous != modelId {
            await dropAdvertisedBuild(previous)
        }
        return true
    }

    /// Scan the on-disk snapshot for a freshly-prefetched model to produce an
    /// advertised `ModelInfo` (type, quantization, size, memory estimate).
    /// Static + nonisolated so it can run inside the off-actor hashing task.
    private static func scanVerifiedModelInfo(modelId: String) -> ModelInfo? {
        guard let snapshot = ModelScanner.resolveLocalPath(modelID: modelId) else { return nil }
        return ModelScanner.parseModelInfo(snapshotDir: snapshot, modelName: modelId)
    }
}
