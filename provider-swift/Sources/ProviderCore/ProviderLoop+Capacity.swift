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
        let heartbeatInterval = max(1, loopConfig.config.coordinator.heartbeatIntervalSecs)
        let pollIntervalNs = UInt64(max(1, heartbeatInterval / 2)) * 1_000_000_000
        let me = self
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
        await recoverWedgedEngineV2Slots()
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
        let mlxActiveBytes = UInt64(max(0, MLX.GPU.activeMemory))
        let mlxPeakBytes = UInt64(max(0, MLX.GPU.peakMemory))
        let mlxCacheBytes = UInt64(max(0, MLX.GPU.cacheMemory))
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
