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
            let cap = await slot.scheduler.backendCapacity()
            allSlots.append(contentsOf: cap.slots)
            let schedCap = await slot.scheduler.capacity()
            totalActive += schedCap.activeRequests
        }

        // ContinuousBatchingV2 (flag-gated, additive): fold any active v2
        // bridge slots into the SAME heartbeat payload — identical protocol
        // fields, truthful bytes-derived token numbers (see
        // `EngineV2Bridge+Capacity`). The registry is empty when the v2
        // engine is off (`DARKBLOOM_ENGINE_V2` unset / `engine_v2 = false`),
        // so legacy behavior is unchanged.
        let engineV2 = await EngineV2Runtime.shared.capacitySummary()
        allSlots.append(contentsOf: engineV2.slots)
        totalActive += engineV2.activeRequests

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
    }

}
