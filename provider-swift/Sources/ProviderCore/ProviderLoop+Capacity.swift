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
        let pollInterval = Duration.seconds(Int64(max(1, heartbeatInterval / 2)))
        let me = self
        capacityRefreshTask = Task {
            // Write once immediately so `status`/`doctor` have a fresh file soon
            // after the daemon starts, before the first poll interval elapses.
            await me.writeDaemonState()
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                if Task.isCancelled { break }
                await me.updateAggregateCapacity()
                // Refresh the diagnostics state file on the same cadence so
                // `status`/`doctor` see current model, stats, and capacity.
                await me.writeDaemonState()
            }
        }
    }

    internal func updateAggregateCapacity() async {
        var allSlots: [BackendSlotCapacity] = []
        var totalActive = 0
        let slots = modelSlots.filter { !modelsUnloading.contains($0.key) }
        for (_, slot) in slots {
            // A v2-served slot reports through its bridge (folded in below via
            // the runtime). Its legacy scheduler is a dormant fallback that
            // serves no requests while the bridge exists — reporting BOTH
            // would advertise the same model's capacity twice and over-admit.
            if slot.engineV2 != nil { continue }
            let cap = await slot.scheduler.backendCapacity()
            allSlots.append(contentsOf: cap.slots)
            let schedCap = await slot.scheduler.capacity()
            totalActive += schedCap.activeRequests
        }

        // ContinuousBatchingV2 (flag-gated, additive): fold any active v2
        // bridge slots into the SAME heartbeat payload — identical protocol
        // fields, truthful bytes-derived token numbers (see
        // `EngineV2Bridge+Capacity`). Guarded on the slot set so the flag-off
        // steady state pays ZERO extra cost here — no runtime actor hop, no
        // allocations; legacy behavior is byte-identical.
        if hasEngineV2Slots {
            // Fleet context for the v2 budget clamp (round-3 PR#499 P2): v2
            // ceilings are construction-fixed, so a model loaded AFTER a
            // bridge (legacy or v2) would otherwise leave that bridge's
            // heartbeat advertising a stale `activeTokenBudgetMax` — the
            // coordinator keeps routing what the shared KV gate then rejects
            // post-acceptance. Snapshot the CURRENT resident set (ALL slots'
            // weights — v2 and legacy, including slots mid-unload whose
            // weights are still resident) + the operator reserve so the
            // runtime can recompute each bridge's live budget and clamp the
            // reported max. Heartbeat cadence only — never the submit path.
            var totalResidentWeightBytes: UInt64 = 0
            for (_, slot) in modelSlots {
                let weights = await slot.scheduler.modelWeightBytes
                let (sum, overflow) = totalResidentWeightBytes
                    .addingReportingOverflow(UInt64(max(0, weights)))
                totalResidentWeightBytes = overflow ? .max : sum
            }
            let engineV2 = await engineV2Runtime.capacitySummary(
                fleetKV: EngineV2Runtime.FleetKVContext(
                    totalResidentWeightBytes: totalResidentWeightBytes,
                    configReserveBytes: Self.memoryReserveBytes(
                        forGiB: loopConfig.config.provider.memoryReserveGB)))
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

        // The real slot-cap guard counts resident slots, while in-progress and
        // globally queued loads have committed future slots. Use a union because
        // the success path installs modelSlots[model] before clearing modelsLoading.
        var occupiedModelIDs = Set(modelSlots.keys)
        occupiedModelIDs.formUnion(modelsLoading)
        occupiedModelIDs.formUnion(loadGateWaitingModels.keys)

        state.backendCapacity = BackendCapacity(
            slots: allSlots,
            gpuMemoryActiveGb: Double(MLX.GPU.activeMemory) / gbDivisor,
            gpuMemoryPeakGb: Double(MLX.GPU.peakMemory) / gbDivisor,
            gpuMemoryCacheGb: Double(MLX.GPU.cacheMemory) / gbDivisor,
            totalMemoryGb: Double(totalMem) / gbDivisor,
            freeForLoadGb: freeForLoadGb,
            maxModelSlots: maxModelSlots,
            // `allSlots` intentionally omits models being unloaded so the
            // coordinator cannot route to them. Resident entries plus loads
            // already in progress are the slot commitments the next load sees.
            occupiedModelSlots: occupiedModelIDs.count
        )
        state.inferenceActive = totalActive > 0
    }

}
