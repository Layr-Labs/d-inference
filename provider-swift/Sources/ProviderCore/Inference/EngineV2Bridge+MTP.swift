import Foundation
import MLXLMCommon
#if canImport(os)
import os
#endif

extension EngineV2Bridge {
    #if canImport(os)
    private static let mtpLogger = Logger(
        subsystem: "com.darkbloom.provider", category: "engine_v2_mtp")
    #endif

    /// Record MTP activation, emit the opening per-slot posture, and
    /// (re)start the periodic sampler.
    ///
    /// The sampler is deliberately NOT gated on MTP being active. It also
    /// carries paged-pool occupancy, which a slot with no drafter must still
    /// report, and `mtp_enabled: false` is itself the observation that makes
    /// a partially-MTP fleet resolvable. `metricsInterval == .zero` still
    /// disables the whole producer, opening sample included (tests).
    ///
    /// The opening sample is emitted BEFORE the first sleep. Waiting a full
    /// interval means a slot that fails post-build, crashes, or is
    /// swapped/unloaded inside its first minute is torn down having never
    /// reported at all — and those short-lived slots (MTP fallback,
    /// rollout failure) are exactly what this inventory exists to expose.
    /// It runs inline rather than as the loop's first iteration so the
    /// emission is ordered before this call returns: a caller that shuts the
    /// bridge down immediately still gets exactly one posture event, with no
    /// dependency on when the child task first gets scheduled.
    func configureMTPStatus(
        _ status: MTPActivationStatus,
        metricsInterval: Duration = .seconds(60),
        sleep: @escaping @Sendable (Duration) async throws -> Void = taskSleep
    ) {
        mtpActivationStatus = status
        slotPostureTask?.cancel()
        slotPostureTask = nil
        guard metricsInterval > .zero else { return }
        sampleSlotPosture()
        let bridge = self
        slotPostureTask = Task { [weak bridge] in
            while !Task.isCancelled {
                try? await sleep(metricsInterval)
                if Task.isCancelled { return }
                guard let bridge else { return }
                await bridge.sampleSlotPosture()
            }
        }
    }

    /// One posture tick: read the engine's MTP metrics ONCE, log it when a
    /// drafter is loaded, and emit the telemetry sample unconditionally.
    private func sampleSlotPosture() {
        let snapshot = mtpStatusSnapshot()
        if mtpActivationStatus.active { logMTPSnapshot(snapshot) }
        emitSlotPostureTelemetry(snapshot)
    }

    /// Public/test-visible lock-safe snapshot. `EngineV2.mtpMetricsSnapshot()`
    /// takes the engine's metrics lock; this adapter never reaches controller
    /// mutation or the inference loop.
    public func mtpStatusSnapshot() -> ProviderMTPStatusSnapshot {
        let metrics = (ownedEngine as? EngineV2)?.mtpMetricsSnapshot()
        return ProviderMTPStatusSnapshot(status: mtpActivationStatus, metrics: metrics)
    }

    private func logMTPSnapshot(_ snapshot: ProviderMTPStatusSnapshot) {
        #if canImport(os)
        let reason = snapshot.fallbackReason?.rawValue ?? "none"
        let revision = snapshot.assistantRevision ?? "none"
        let skipped = snapshot.skippedRows.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        let controller = snapshot.controllerFallbacks.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        Self.mtpLogger.info(
            "mtp metrics model=\(self.modelId, privacy: .public) configured=\(snapshot.configured) active=\(snapshot.active) reason=\(reason, privacy: .public) revision=\(revision, privacy: .public) assistant_bytes=\(snapshot.assistantResidentBytes) depth=\(snapshot.selectedDepth) decode_bucket=\(snapshot.decodeRowBucket) rounds=\(snapshot.rounds) seeds=\(snapshot.seedRows) proposed=\(snapshot.proposedTokens) accepted=\(snapshot.acceptedDraftTokens) emitted=\(snapshot.committedEmittedTokens) skipped=\(skipped, privacy: .public) controller=\(controller, privacy: .public)"
        )
        #endif
    }

    /// This slot's posture: the resolved KV backend plus the three MTP facts,
    /// under the model id the bridge itself holds.
    ///
    /// ONE producer for BOTH consumers, which is the point. The fleet-facing
    /// `engine_v2_slot_posture` telemetry event and the box-facing
    /// `DaemonState.slots` inventory that `darkbloom status` / `doctor` render
    /// used to assemble this 4-tuple independently from the same two sources.
    /// Their agreement was a coincidence maintained by hand — and the daemon
    /// side keyed `model` off the caller's dictionary key while telemetry used
    /// `bridge.modelId`, so the two could in principle name the same slot
    /// differently. Both now read this.
    ///
    /// `nonisolated`: it reads only `let` state (`modelId`, `kvBackendKind`)
    /// plus the snapshot the caller already awaited, so the capacity tick does
    /// not pay a second actor hop per slot to assemble it.
    nonisolated func slotPosture(
        _ snapshot: ProviderMTPStatusSnapshot
    ) -> DaemonSlotPostureBuilder.LiveSlot {
        DaemonSlotPostureBuilder.LiveSlot(
            model: modelId,
            kvBackend: kvBackendKind.rawValue,
            // The heartbeat-clamped copy, so the box-side `status` line and
            // the fleet-side `kv_backend_fallback_reason` carry the SAME
            // string — a truncated tail on both rather than two variants.
            kvBackendFallbackReason: clampedKVBackendFallbackReason,
            mtpEnabled: snapshot.configured,
            mtpActive: snapshot.active,
            mtpInactiveReason: snapshot.fallbackReason?.rawValue)
    }

    /// The producer for the v0.8.0 MTP and paged-pool telemetry fields.
    ///
    /// WHY THIS EMISSION POINT. These fields exist so a paged rollout can be
    /// judged with no canary fleet, and that needs a FLEET INVENTORY: every
    /// loaded slot, recurring, independent of traffic. Three shapes that are
    /// not that, all present in this codebase already:
    ///
    ///   * Once per engine construction — the `engine_v2_kv_backend` event's
    ///     mistake (EngineV2Config). It rides a best-effort sink that DROPS
    ///     ON FULL behind a 100/min limit, so a single event per model load
    ///     is a notification, not an inventory: miss it and the slot is
    ///     invisible until the next restart.
    ///   * Per request — an idle slot vanishes from the fleet view, and
    ///     `inert_kv_unsupported` is precisely a slot that charges full
    ///     drafter residency while producing nothing.
    ///   * Edge triggered, like `step_wedge` — a healthy slot never reports,
    ///     so "no event" and "no provider" are indistinguishable.
    ///
    /// A per-bridge timer on the existing 60 s MTP cadence satisfies all
    /// three, is bounded fleet-wide (one event per slot per minute, and
    /// `max_model_slots` defaults to 3), and runs off the inference hot path.
    /// The per-slot every-heartbeat channel is `BackendSlotCapacity`, which
    /// already carries `kv_backend`; this is its telemetry-side counterpart.
    /// Internal rather than private so a test can drive it with a
    /// hand-built snapshot: the inert state needs `CBv2MTPMetrics`, which
    /// only a concrete `EngineV2` produces, and standing up a real engine
    /// would make this a weights-and-Metal test instead of a field test.
    func emitSlotPostureTelemetry(_ snapshot: ProviderMTPStatusSnapshot) {
        let posture = slotPosture(snapshot)
        var fields: [String: AnyCodableValue] = [
            "mtp_enabled": .bool(posture.mtpEnabled),
            "mtp_active": .bool(posture.mtpActive),
        ]
        // Present whenever MTP is not PRODUCTIVELY running, which includes
        // `inert_kv_unsupported` — enabled, drafter resident, zero rounds.
        // Absent only when MTP is genuinely producing rounds.
        if let reason = posture.mtpInactiveReason {
            fields["mtp_inactive_reason"] = .string(reason)
        }
        // OMITTED, never 0.0, when nothing was proposed. A zero would read as
        // "the target rejects every draft" rather than "no drafts existed",
        // and would drag any unweighted fleet average toward zero.
        //
        // The CUMULATIVE counters ride along as the ratio's own weights: a
        // roll-up must weight each sample by its proposed-token count, and a
        // ratio without its denominator cannot be weighted — a 1/1 slot and
        // a 10,000/10,000 slot were indistinguishable, and averaging the
        // recurring per-slot events both biased fleet acceptance toward
        // low-volume slots and re-counted old cumulative history every tick.
        // Cumulative rather than per-interval deltas, deliberately: the
        // sampler has no ack from the sink (events can be dropped on full),
        // so a delta that failed to land would be lost forever, while
        // cumulative counters let the reader difference any two samples that
        // DID land — the standard counter contract.
        if snapshot.proposedTokens > 0 {
            fields["mtp_acceptance_rate"] = .double(
                Double(snapshot.acceptedDraftTokens) / Double(snapshot.proposedTokens))
            fields["mtp_proposed_tokens"] = .int(snapshot.proposedTokens)
            fields["mtp_accepted_tokens"] = .int(snapshot.acceptedDraftTokens)
        }
        // Paged pool occupancy, in BYTES over bytes — not pages over pages.
        // `PagedKVPool` exposes only bytesInUse/bytesReserved/bytesCapacity;
        // its page counters are per-group and internal. The byte ratio is a
        // page ratio weighted by page size (pageBytes differs per (kvHeads,
        // headDim) group), which is the more useful occupancy figure anyway.
        // Stated here and in the schema doc so the units cannot silently
        // drift — that drift is the whole reason `backend` had to be split.
        //
        // In-use, not reserved: reserved is the worst-case admission charge
        // and would report a pool as full while its pages are still cold.
        // A zero backend capacity means UNKNOWN (test stubs, idle
        // point-updates), never an empty pool, so the key is omitted.
        if kvBackendKind == .paged {
            let capacity = capacitySnapshot()
            if capacity.kvBytesBackendCapacity > 0 {
                let used = Double(max(0, capacity.kvBytesInUse))
                fields["pool_utilization"] = .double(
                    min(1.0, used / Double(capacity.kvBytesBackendCapacity)))
            }
        }
        // `pages_pinned` and `cow_events` have NO producer here on purpose.
        // Neither mechanism exists yet: PagedKVPool has no pin concept (only
        // reserve/in-use), and copy-on-write page splitting is unimplemented
        // — "today every page has refcount 0 or 1" (PagedKVPool.swift header).
        // Emitting a hardcoded 0 would be indistinguishable from a measured
        // zero and would make the dashboard assert a fact nothing observed.
        //
        // For the same reason the two keys are no longer ALLOWLISTED either:
        // a key that survives the filter but is never written reads as a
        // legitimate zero to anyone building a panel on it. Add each key in
        // the same change as its mechanism, across all three mirrors.
        emit(
            EngineHealthEvent.make(
                severity: .info,
                message: "engine_v2: slot posture",
                operation: "engine_v2_slot_posture",
                model: posture.model,
                kvBackend: posture.kvBackend,
                extra: fields))
    }
}
