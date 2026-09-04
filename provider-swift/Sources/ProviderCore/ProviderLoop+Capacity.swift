/// ProviderLoop -- aggregate capacity reporting.
///
/// The periodic capacity-refresh heartbeat driver and `updateAggregateCapacity`,
/// which rolls up per-model scheduler capacity + free-memory headroom for the coordinator.

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
    // MARK: - Capacity Refresh

    internal func startCapacityRefreshMonitor() {
        capacityRefreshTask?.cancel()
        daemonStateLivenessTask?.cancel()
        let heartbeatInterval = max(1, loopConfig.config.coordinator.heartbeatIntervalSecs)
        // Integer division: at the default 5 s heartbeat this is a 2 s poll
        // (the "~half-heartbeat" the daemon-state staleness bars assume).
        let pollIntervalNs = UInt64(max(1, heartbeatInterval / 2)) * 1_000_000_000
        let me = self
        // Liveness stamp on its own task, same cadence, never awaiting an
        // engine bridge: `currentDaemonState()` is synchronous on the loop
        // actor and reads the postures the last completed tick cached, so
        // `written_at` keeps advancing while a tick below is parked on a
        // stalled bridge (the same shape as `startPreloadLivenessRefresh`).
        // The tick still writes at its end so the diagnostic payload is fresh
        // the moment a rebuild completes; both writes run on the actor, so
        // they are serialized and `written_at` never regresses. Default
        // priority, not `.utility`: this stamp is what keeps the watchdog
        // from restarting a busy daemon, so it must not be the first thing a
        // saturated cooperative pool starves.
        // ...but gated on tick PROGRESS (`stampLivenessIfTickProgressing`):
        // a tick parked past `livenessTickProgressBound` is a bridge that
        // is wedged, not busy, and the stamp stops so the watchdog's
        // restart — the only recovery for a blocked bridge actor — still
        // fires.
        lastCapacityTickCompleted = .now
        daemonStateLivenessTask = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: pollIntervalNs)
                if Task.isCancelled { break }
                await me.stampLivenessIfTickProgressing()
            }
        }
        capacityRefreshTask = Task {
            // Write once immediately so `status`/`doctor` have a fresh file soon
            // after the daemon starts, before the first poll interval elapses.
            await me.writeDaemonState()
            while !Task.isCancelled {
                // `Task.sleep(nanoseconds:)` — NOT the Duration/Clock
                // overload. Under -O (Swift 6.3, macOS 26) the generic
                // `taskSleep(tolerance:clock:)` inlined into this loop
                // aborted the process ~2 s after startup with the task
                // allocator's "freed pointer was not the last allocation"
                // (swift_task_dealloc LIFO violation) — reproduced 100% in
                // the E2E harness from the v0.7.5 integration head and
                // absent in debug builds. The non-generic nanoseconds
                // overload takes a different codegen path and is stable.
                // See the v0.7.5 integration report; revisit on a toolchain
                // bump.
                try? await Task.sleep(nanoseconds: pollIntervalNs)
                if Task.isCancelled { break }
                // One actor hop per tick: capacity snapshot, wedge
                // self-recovery (ProviderLoop+EngineV2Liveness — the
                // capacity snapshot is where the v2 wedge verdict
                // surfaces and this is what ACTS on a confirmed one),
                // then the diagnostics state file for `status`/`doctor`.
                await me.capacityRefreshTick()
            }
        }
    }

    /// One capacity-monitor tick, isolated on the loop actor.
    internal func capacityRefreshTick() async {
        // Proactive trim of the MLX reclaimable buffer pool (DAR-338). Freed
        // KV/activation buffers otherwise sit in MLX's cache up to the cache
        // limit and are never returned to the OS — under sustained serving the
        // pool grows monotonically (each completed request parks its buffers)
        // until macOS memory pressure fires. The legacy engine's liveness
        // watchdog drove this sweep every 2s until the v0.7.5 engine deletion
        // removed it with its host; this tick is that watchdog's documented
        // successor. Non-blocking: only signals the off-actor reclaimer
        // (rate-limited, threshold-gated); the GPU sync never runs here.
        kvBudget.proactiveReclaimSweep()
        await updateAggregateCapacity()
        await sampleLiveSlotPostures()
        // ONCE per tick, deliberately outside `updateAggregateCapacity`
        // (which re-enters itself on the reserve-epoch guard and also runs
        // on every request event): the MLX over-limit regime sampler.
        sampleMLXMemoryLimitRegime()
        await recoverWedgedEngineV2Slots()
        writeDaemonState()
        lastCapacityTickCompleted = .now
    }

    /// The liveness task's write. A stalled BRIDGE leaves the loop actor
    /// free and this keeps `written_at` advancing — until the tick has gone
    /// `livenessTickProgressBound` without completing: `capacitySummary`
    /// awaits every bridge and `recoverWedgedEngineV2Slots` needs the same
    /// actor, so a bridge blocked that long can never self-recover, every
    /// `finishInflightRequest` parks on it, and the coordinator routes on a
    /// stale snapshot. Withholding the stamp lets the file go stale and the
    /// watchdog restart the daemon: a false positive needs the tick blocked
    /// for bound + 90 s staleness + the watchdog's 300 s grace — a wedge,
    /// never a busy slot.
    internal func stampLivenessIfTickProgressing() {
        let sinceLastTick = ContinuousClock.now - lastCapacityTickCompleted
        guard sinceLastTick <= livenessTickProgressBound else {
            if !livenessWithheldLogged {
                livenessWithheldLogged = true
                logger.warning(
                    "Capacity tick has not completed for \(sinceLastTick.components.seconds)s (bound \(livenessTickProgressBound.components.seconds)s): withholding the watchdog liveness stamp so a wedged engine bridge is recovered by restart")
            }
            return
        }
        if livenessWithheldLogged {
            livenessWithheldLogged = false
            logger.info("Capacity tick completed again; watchdog liveness stamp resumed")
        }
        writeDaemonState()
    }

    /// Per-slot KV-backend + MTP posture for the diagnostics state file
    /// (`darkbloom status` / `doctor`). Sampled on the capacity TICK only —
    /// `mtpStatusSnapshot()` is an actor hop per slot and the value is a
    /// diagnostic nobody on the request path reads — right after the same
    /// rebuild that reports `BackendSlotCapacity.kv_backend` to the
    /// coordinator, so the box and the fleet cannot disagree about which
    /// backend a slot resolved to.
    ///
    /// EVERY slot, not just the advertised ones: a model that is loaded but
    /// not advertised is still occupying memory on the backend an operator
    /// is asking about. Assembled by the BRIDGE (`slotPosture`), not here,
    /// so this and the `engine_v2_slot_posture` telemetry event cannot
    /// describe the same slot differently.
    internal func sampleLiveSlotPostures() async {
        var postures: [DaemonSlotPostureBuilder.LiveSlot] = []
        postures.reserveCapacity(modelSlots.count)
        for (_, slot) in modelSlots {
            let bridge = slot.engineV2
            postures.append(bridge.slotPosture(await bridge.mtpStatusSnapshot()))
        }
        lastLiveSlotPostures = postures
    }

    /// MLX active-over-limit regime detector (T13-05, `MLXMemoryLimitRegime`).
    /// Above `Memory.memoryLimit` MLX's eval commits and waits after EVERY
    /// primitive — a silent ~10× decode slowdown shaped exactly like a wedged
    /// slot. Edge-triggered: WARN + `engine_health` telemetry
    /// (`operation=mlx_memory_limit_exceeded`) on entry, INFO +
    /// `mlx_memory_limit_recovered` on exit, a tick counter while over. The
    /// limit comes from `MLXMemoryGuard.configuredLimitsSnapshot()` — the
    /// value this process set — never from an MLX global read (which can
    /// initialize Metal in no-GPU tests); the test seam overrides it.
    internal func sampleMLXMemoryLimitRegime() {
        let active = max(0, MLX.Memory.activeMemory)
        let limit = mlxMemoryLimitBytesForTesting
            ?? MLXMemoryGuard.configuredLimitsSnapshot()?.memoryLimitBytes
        let transition = MLXMemoryLimitRegime.transition(
            activeBytes: active, limitBytes: limit, wasOver: mlxOverLimit)
        switch transition {
        case .none:
            if mlxOverLimit { mlxOverLimitTicks += 1 }
            return
        case .enter:
            mlxOverLimit = true
            mlxOverLimitTicks += 1
        case .exit:
            mlxOverLimit = false
        }
        let entered = transition == .enter
        let limitBytes = limit ?? 0
        let ratio = limitBytes > 0 ? Double(active) / Double(limitBytes) : 0
        let message = entered
            ? String(
                format: "MLX active memory %d B above memory limit %d B (×%.2f) — eval "
                    + "serializes per primitive until active drops below the limit",
                active, limitBytes, ratio)
            : String(
                format: "MLX active memory %d B back below memory limit %d B (×%.2f) after "
                    + "%d over-limit tick(s)",
                active, limitBytes, ratio, mlxOverLimitTicks)
        if entered { logger.warning(message) } else { logger.info(message) }
        // Allowlisted keys only (the limit rides the message); the engine_v2
        // health kind + the slot-hook sink so the loop-level test can capture
        // it — production falls through to the shared client.
        let event = TelemetryEvent(
            source: .provider,
            severity: entered ? .warn : .info,
            kind: .engineHealth,
            message: message
        ).withFields([
            "component": .string("engine"),
            "operation": .string(
                entered ? "mlx_memory_limit_exceeded" : "mlx_memory_limit_recovered"),
            "backend": .string("engine_v2"),
            "mlx_active_bytes": .int64(Int64(active)),
            "mlx_cache_bytes": .int64(Int64(max(0, MLX.Memory.cacheMemory))),
            "num_running": .int(modelSlots.count),
        ])
        if let emit = engineV2SlotHooks?.emitTelemetry {
            emit(event)
        } else {
            TelemetryClient.shared.emit(event)
        }
    }

    /// `attempt`: internal retry counter for the stale-snapshot guard below;
    /// callers use the default.
    internal func updateAggregateCapacity(attempt: Int = 0) async {
        // Reserve epoch at entry: the hops below (engine summary, KV
        // outstanding) are actor suspensions, and a reserve push landing
        // across them (a verified prefetch raising the floor, a retirement
        // relaxing it, a load's own marker transitions) would leave this
        // invocation publishing pre-push figures. Not every push site
        // publishes a replacement, so a tripped guard RECOMPUTES rather
        // than returns (bounded: the third attempt publishes regardless —
        // a snapshot one epoch behind beats none until the next tick).
        let reserveEpochAtEntry = activationReserveEpoch
        // ONE ENGINE (v0.7.5): `EngineV2Runtime.capacitySummary` is the ONLY
        // slot source — every loaded model serves through a v2 bridge; the
        // legacy scheduler fold is gone. Same `BackendSlotCapacity` wire
        // shape, same slot-state strings ("idle"/"running"/"crashed").
        var allSlots: [BackendSlotCapacity] = []
        var totalActive = 0
        if hasEngineV2Slots {
            // Fleet context for the v2 budget clamp: engine grants are now
            // RE-SLICED at load/unload, so between re-slices this clamp is a
            // near-inert safety net — but it stays: it recomputes each
            // bridge's live budget from CURRENT fleet residency (weights of
            // ALL slots, including mid-unload ones whose bytes are still
            // resident) so the reported max can never advertise capacity the
            // shared KV gate would reject. The runtime reads each engine's
            // CURRENT (post-re-slice) grant per heartbeat — never a stale
            // construction-time figure. Heartbeat cadence only.
            var totalResidentWeightBytes: UInt64 = 0
            for (_, slot) in modelSlots {
                let (sum, overflow) = totalResidentWeightBytes
                    .addingReportingOverflow(UInt64(max(0, slot.sizing.weightsBytes)))
                totalResidentWeightBytes = overflow ? .max : sum
            }
            // Physical memory MUST come from the same source the re-slice
            // grant arithmetic uses (`fleetKVBudgetBytes`): the test hooks'
            // override when installed, the machine's real memory otherwise.
            // Mixing sources makes the clamp bind spuriously on any box
            // smaller than the hooked figure (grants computed against the
            // override, clamp against real RAM) — nil hooks ⇒ production
            // behavior unchanged.
            let engineV2 = await engineV2Runtime.capacitySummary(
                fleetKV: EngineV2Runtime.FleetKVContext(
                    totalResidentWeightBytes: totalResidentWeightBytes,
                    activationReserveBytes: resolvedActivationReserveBytes,
                    configReserveBytes: Self.memoryReserveBytes(
                        forGiB: loopConfig.config.provider.memoryReserveGB),
                    physicalBytes: engineV2SlotHooks?.physicalMemoryBytes
                        ?? ProcessInfo.processInfo.physicalMemory))
            allSlots.append(contentsOf: engineV2.slots)
            totalActive += engineV2.activeRequests
        }
        // Refusing new work (shutdown drain, update drain): every admitting
        // slot is reported `reloading` — the one state the scheduler prices
        // as not routable while the cache status still counts the model
        // loaded — so the coordinator stops selecting this box instead of
        // routing into the slot_state 503 for the whole drain window.
        // Applied on EVERY rebuild (a request finishing rebuilds too), not
        // only at drain start, or the next rebuild would re-advertise.
        if isShuttingDown || isDrainingForUpdate {
            allSlots = Self.withdrawingAdmission(from: allSlots)
        }

        let gbDivisor = 1024.0 * 1024.0 * 1024.0
        let totalMem = ProcessInfo.processInfo.physicalMemory

        // Max model weight we could load right now (single source of truth for
        // the coordinator's cold-load routing). Holds back the same load reserve
        // the load gate uses, so it enforces the 90% cap.
        //
        // Eviction handling: current MLX usage may be reclaimed by evicting idle
        // models on a cold load — BUT ONLY when nothing is being served. MLX
        // memory is global (it also covers the local inference endpoint, whose
        // streams are tracked by localReservations, not modelSlots), so a model
        // serving a local request is NOT evictable. `hasInflightWork` is the
        // comprehensive signal (coordinator inflight + local streams): when work
        // is in flight we treat NOTHING as reclaimable (conservative, never
        // advertises an actively-served model's weights as free); only when fully
        // idle do we assume idle models can be evicted.
        let mlxActiveBytes = UInt64(max(0, MLX.Memory.activeMemory))
        // Heartbeat `gpu_memory_peak_gb` is the peak since the LAST MODEL LOAD
        // (the load path resets MLX's peak counter to measure its transient,
        // T3-08), not since process start. No routing consumer reads it; the
        // profiler's fleet_snapshots column inherits the same semantics.
        let mlxPeakBytes = UInt64(max(0, MLX.Memory.peakMemory))
        let mlxCacheBytes = UInt64(max(0, MLX.Memory.cacheMemory))
        let mlxUsed = mlxActiveBytes + mlxCacheBytes
        let reclaimableMlx: UInt64 = hasInflightWork ? 0 : mlxUsed
        let loadReserve = UnifiedMemoryCap.loadReserveBytes(
            configReserveBytes: Self.memoryReserveBytes(forGiB: loopConfig.config.provider.memoryReserveGB))
        // Subtract KV already promised to in-flight requests (coordinator + local
        // streams), exactly as the real load gate (availableMemoryGb) does, so the
        // heartbeat can't advertise reserved-but-not-yet-allocated bytes as loadable.
        let outstandingKV = await kvBudget.outstandingReservedBytes()
        let freeForLoadGb = ModelLoadAdmission.maxLoadableWeightGb(
            totalBytes: totalMem,
            systemAvailableBytes: SystemMemory.availableBytes() ?? .max,
            mlxUsedBytes: reclaimableMlx,
            reserveBytes: loadReserve,
            // The serving set's resolved headroom (measured per-model floors),
            // not the flat default — free_for_load_gb must mirror the load
            // gate this box actually applies (ensureModelLoaded), or the
            // coordinator's cold-load routing desyncs from it.
            headroomGb: loadHeadroomGb,
            outstandingReservationBytes: outstandingKV)
        let reclaimer = kvBudget.cacheReclaimerTelemetrySnapshot()
        let reclaimerTelemetry = MLXCacheReclaimerTelemetry(
            cacheLimitBytes: UInt64(max(
                0, MLXMemoryGuard.configuredLimitsSnapshot()?.cacheLimitBytes ?? 0)),
            sweepSignals: reclaimer.sweepSignals,
            reclaims: reclaimer.reclaims,
            reclaimedBytes: reclaimer.reclaimedBytes,
            lastReclaimedBytes: reclaimer.lastReclaimedBytes,
            lastReclaimDurationMs: reclaimer.lastReclaimDurationMs)

        // Stale-snapshot guard (see the epoch capture at entry): the reserve
        // moved while this invocation was suspended — slot budgets and
        // free_for_load_gb here predate the floor the KV gate already
        // enforces. Recompute over the current state instead of publishing
        // them; bounded so a push storm cannot starve the publish.
        guard activationReserveEpoch == reserveEpochAtEntry || attempt >= 2 else {
            logger.info(
                "Capacity snapshot recomputed: activation reserve moved during refresh (attempt \(attempt + 1))")
            return await updateAggregateCapacity(attempt: attempt + 1)
        }

        // Profiler process posture (slice 2). ALWAYS attached — the object's
        // presence is the coordinator's "new provider" sentinel.
        let pressureLevel: MemoryPressureLevelWire
        switch lastMemoryPressureLevel.value {
        case .normal: pressureLevel = .normal
        case .warning: pressureLevel = .warning
        case .critical: pressureLevel = .critical
        }
        let capacityTelemetry = CapacityTelemetry(
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            memoryPressureLevel: pressureLevel,
            mlxNumResources: Int64(max(0, MLX.Memory.numResources)),
            inAdmission: Int64(requestToModel.count),
            inflightTasks: Int64(inflightTasks.count))

        state.backendCapacity = BackendCapacity(
            slots: allSlots,
            gpuMemoryActiveGb: Double(mlxActiveBytes) / gbDivisor,
            gpuMemoryPeakGb: Double(mlxPeakBytes) / gbDivisor,
            gpuMemoryCacheGb: Double(mlxCacheBytes) / gbDivisor,
            totalMemoryGb: Double(totalMem) / gbDivisor,
            freeForLoadGb: freeForLoadGb,
            mlxCacheReclaimer: reclaimerTelemetry,
            telemetry: capacityTelemetry
        )
        state.inferenceActive = totalActive > 0
        let loadedSlots = modelSlots.compactMap { modelId, slot
            -> (String, EngineV2Bridge)? in
            guard advertisedModels[modelId] != nil else { return nil }
            return (modelId, slot.engineV2)
        }
        state.setPrefixCacheSnapshot(
            sources: Dictionary(uniqueKeysWithValues: loadedSlots.compactMap { modelId, bridge in
                bridge.ssdPrefixCache.map { (modelId, $0) }
            }),
            statuses: loadedSlots.map { _, bridge in bridge.prefixCacheModelStatus() },
            runtimeIdentityAvailable: binaryHash?.isEmpty == false)

        // The per-slot MTP/KV-backend posture for the state file is sampled
        // by `capacityRefreshTick` (`sampleLiveSlotPostures`), not here: this
        // rebuild also runs per request, and that posture is a diagnostic.

        // Routing v2, Phase 1: every capacity rebuild flows through here —
        // request admitted (post-submit refresh), completed/cancelled, model
        // loaded/unloaded/evicted, wedge recovery flipping a slot to
        // "crashed"/"reloading", and the periodic tick that picks up token
        // budget drift. Comparing the fresh payload against the last SENT
        // heartbeat's payload (the published snapshot) is therefore the one
        // seam that implements all of the plan's event triggers without
        // forking any of those call sites.
        scheduleEventHeartbeatIfMaterial()
    }

    /// Slot-state fold for a provider that refuses new work: every slot but
    /// a `crashed` one is reported `reloading`, the coordinator's existing
    /// "loaded, not admitting" state (`slotStatePenalty` prices it +Inf and
    /// not routable; the cache status still counts the model resident).
    internal static func withdrawingAdmission(
        from slots: [BackendSlotCapacity]
    ) -> [BackendSlotCapacity] {
        slots.map { slot in
            guard slot.state != "crashed" else { return slot }
            var withdrawn = slot
            withdrawn.state = "reloading"
            return withdrawn
        }
    }

    /// Drain start: fold the LAST rebuilt snapshot in place — deliberately no
    /// `updateAggregateCapacity`, which awaits every engine bridge and would
    /// park a shutdown behind a wedged bridge before the drain's own bound —
    /// and fire one event heartbeat so the coordinator stops routing here
    /// within a heartbeat rather than at the close. Later rebuilds keep the
    /// posture through the `isShuttingDown || isDrainingForUpdate` fold.
    internal func publishDrainingCapacity() {
        if var capacity = state.backendCapacity {
            capacity.slots = Self.withdrawingAdmission(from: capacity.slots)
            state.backendCapacity = capacity
        }
        guard let client = coordinatorClient else { return }
        Task { await client.sendEventHeartbeat() }
    }

    /// Fire (or schedule) an out-of-band heartbeat when the freshly rebuilt
    /// capacity materially differs from the last one the coordinator saw.
    /// Rate-capped at 2/s with trailing-edge coalescing; a change inside the
    /// cap window is never dropped — the trailing timer guarantees exactly
    /// one heartbeat at window end carrying the then-current payload. The 5s
    /// baseline heartbeat keeps running untouched as liveness.
    internal func scheduleEventHeartbeatIfMaterial() {
        guard let capacity = state.backendCapacity else { return }
        guard CapacityHeartbeatMateriality.isMaterial(
            previous: state.publishedCapacity, current: capacity)
        else { return }
        switch capacityHeartbeatThrottle.noteMaterialChange(now: .now) {
        case .sendNow:
            guard let client = coordinatorClient else { return }
            Task { await client.sendEventHeartbeat() }
        case .scheduled(let after):
            let me = self
            // `Task.sleep(nanoseconds:)`, NOT the Duration/Clock overload —
            // same -O task-allocator crash documented on the capacity poll
            // loop above.
            let delayNs = UInt64(max(0, after.components.seconds)) * 1_000_000_000
                + UInt64(max(0, after.components.attoseconds / 1_000_000_000))
            trailingHeartbeatTask = Task {
                try? await Task.sleep(nanoseconds: delayNs)
                if Task.isCancelled { return }
                await me.fireTrailingEventHeartbeat()
            }
        case .coalesced:
            break
        }
    }

    /// Trailing-edge send: services the one scheduled verdict. Deliberately
    /// does NOT rebuild capacity first — `state.backendCapacity` already
    /// holds the latest rebuild (that rebuild is what coalesced into this
    /// timer), and rebuilding here would re-enter the materiality check.
    internal func fireTrailingEventHeartbeat() async {
        trailingHeartbeatTask = nil
        guard capacityHeartbeatThrottle.takeScheduledSend(now: .now) else { return }
        await coordinatorClient?.sendEventHeartbeat()
    }

}
