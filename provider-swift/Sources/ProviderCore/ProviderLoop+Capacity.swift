/// ProviderLoop -- aggregate capacity reporting.
///
/// The periodic capacity-refresh heartbeat driver and `updateAggregateCapacity`,
/// which rolls up per-model scheduler capacity + free-memory headroom for the coordinator.

import CryptoKit
import Foundation
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
        writeDaemonState()
    }

    internal func updateAggregateCapacity() async {
        do {
            let snapshot = try await inferenceWorkerClient.capacitySnapshot()
            guard snapshot.launchIdentifier == inferenceWorkerIdentity?.launchIdentifier else {
                throw InferenceWorkerClientError.invalidated
            }
            let slots = snapshot.entries.compactMap { entry -> BackendSlotCapacity? in
                guard entry.state == 2 || entry.activeRequests > 0 else { return nil }
                if let encoded = entry.capacityJSON,
                   let exact = try? JSONDecoder().decode(
                    BackendSlotCapacity.self, from: encoded),
                   exact.model == entry.modelIdentifier {
                    return exact
                }
                return BackendSlotCapacity(
                    model: entry.modelIdentifier,
                    state: entry.activeRequests > 0 ? "running" : "idle",
                    numRunning: UInt32(entry.activeRequests),
                    numWaiting: UInt32(entry.queuedRequests),
                    activeTokens: 0,
                    maxTokensPotential: 0,
                    maxConcurrency: UInt32(entry.maximumRequests),
                    kvBytesPerToken: Int64(clamping: entry.kvBytes))
            }
            let divisor = 1024.0 * 1024.0 * 1024.0
            state.backendCapacity = BackendCapacity(
                slots: slots,
                gpuMemoryActiveGb: Double(snapshot.gpuActiveBytes) / divisor,
                gpuMemoryPeakGb: Double(snapshot.gpuPeakBytes) / divisor,
                gpuMemoryCacheGb: Double(snapshot.gpuCacheBytes) / divisor,
                totalMemoryGb: Double(snapshot.totalMemoryBytes) / divisor,
                freeForLoadGb: Double(snapshot.freeForLoadBytes) / divisor)
            state.inferenceActive = snapshot.entries.contains { $0.activeRequests > 0 }
            let warmEntries = snapshot.entries
                .filter { $0.state == 2 }
                .sorted { $0.modelIdentifier < $1.modelIdentifier }
            state.warmModels = warmEntries.map(\.modelIdentifier)
            let current = warmEntries.first(where: { $0.activeRequests > 0 })
                ?? warmEntries.first
            state.currentModel = current?.modelIdentifier
            state.currentModelHash = current?.manifestSHA256
            let prefixCacheAdvertisement = snapshot.prefixCacheAdvertisementJSON.flatMap {
                try? JSONDecoder().decode(
                    WorkerPrefixCacheAdvertisementMetadata.self, from: $0)
            }
            state.setPrefixCacheSnapshot(
                statuses: [],
                runtimeIdentityAvailable:
                    inferenceWorkerIdentity != nil)
            state.setWorkerPrefixCacheAdvertisement(prefixCacheAdvertisement)
            lastLiveSlotPostures = []
        } catch {
            state.backendCapacity = BackendCapacity(
                slots: [], gpuMemoryActiveGb: 0, gpuMemoryPeakGb: 0,
                gpuMemoryCacheGb: 0,
                totalMemoryGb: Double(ProcessInfo.processInfo.physicalMemory)
                    / (1024.0 * 1024.0 * 1024.0),
                freeForLoadGb: 0)
            state.inferenceActive = false
            state.setWorkerPrefixCacheAdvertisement(nil)
            await workerConnectionFailed()
        }
    }

}
