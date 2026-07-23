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
        await updateAggregateCapacity()
        await recoverWedgedEngineV2Slots()
        writeDaemonState()
    }

    internal func updateAggregateCapacity() async {
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
        let mlxUsed = UInt64(max(0, MLX.GPU.activeMemory)) + UInt64(max(0, MLX.GPU.cacheMemory))
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
            outstandingReservationBytes: outstandingKV)

        state.backendCapacity = BackendCapacity(
            slots: allSlots,
            gpuMemoryActiveGb: Double(MLX.GPU.activeMemory) / gbDivisor,
            gpuMemoryPeakGb: Double(MLX.GPU.peakMemory) / gbDivisor,
            gpuMemoryCacheGb: Double(MLX.GPU.cacheMemory) / gbDivisor,
            totalMemoryGb: Double(totalMem) / gbDivisor,
            freeForLoadGb: freeForLoadGb
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
    }

}
