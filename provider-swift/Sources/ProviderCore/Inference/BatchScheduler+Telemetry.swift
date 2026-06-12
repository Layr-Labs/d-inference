// Copyright © 2026 Eigen Labs.
//
// Telemetry surface for `BatchScheduler`:
//   * `backendCapacity()` — heartbeat payload (active/queued tokens,
//     observed TPS, KV-byte budget).
//   * `recordBatchPerformance` + `updateDynamicMaxConcurrentRequests`
//     — EWMA-driven adaptive concurrency cap (drives `maxNumSeqs` on
//     the underlying engine).
//   * `refreshPendingSummaryCache` — pulls planner pending stats into
//     a cached snapshot so `backendCapacity` doesn't hop the planner
//     actor on every heartbeat.
//
// Access promotions vs the pre-split file:
//   * `recordBatchPerformance`, `updateDynamicMaxConcurrentRequests`,
//     `refreshPendingSummaryCache`, `updateDecodeTpsEwma`,
//     `releaseKVReservation`, `gpuMemory` were `private` — now
//     `internal` so they can be called from the bridge / main file
//     across this set of extensions.

import Foundation
import MLX

extension BatchScheduler {

    // MARK: - Computed admission / capacity properties
    //
    // Read by `submit()` (admission gating), `capacity()` (heartbeat),
    // and `backendCapacity()` below. Live here next to the heartbeat
    // surface since they all share the same accounting view of
    // `activeBridges` + `pendingSummaryCache`.

    /// Memory-aware token budget. Below the static cap when the GPU is
    /// memory-pressured, never exceeds it.
    var tokenBudgetMax: Int {
        let staticBudget = dynamicTokenBudgetMax > 0
            ? dynamicTokenBudgetMax
            : defaultMaxTokens * maxConcurrentRequests
        guard modelWeightBytes > 0, kvBytesPerToken > 0 else {
            return staticBudget
        }

        let totalMemory = Int(ProcessInfo.processInfo.physicalMemory)
        let osReserve = 4 * 1024 * 1024 * 1024
        let safetyMargin = totalMemory / 10
        let globalUsed = Int(MLX.GPU.activeMemory) + Int(MLX.GPU.cacheMemory)
        let availableHeadroom = max(0, totalMemory - osReserve - safetyMargin - globalUsed)
        let liveBudget = activeTokenBudgetUsed + (availableHeadroom / kvBytesPerToken)
        return max(1024, min(staticBudget, liveBudget))
    }

    /// Sum of `(promptTokens + maxTokens)` across active bridges. This
    /// is the value the P1 cumulative-budget gate in `submit()` checks
    /// against `tokenBudgetMax`.
    var activeTokenBudgetUsed: Int {
        activeBridges.values.reduce(0) {
            $0 + ($1.reservedTokens ?? ($1.promptTokens + $1.maxTokens))
        }
    }

    var queuedTokenBudget: Int { pendingSummaryCache.queuedTokens }

    var pendingRequestCount: Int { pendingSummaryCache.queuedRequests }

    var currentTokenBudgetUsed: Int {
        activeTokenBudgetUsed + queuedTokenBudget
    }

    private var averageReservedTokensForAdmission: Int {
        let requestCount = activeBridges.count + pendingRequestCount
        guard requestCount > 0 else { return defaultMaxTokens }
        return max(1, currentTokenBudgetUsed / requestCount)
    }

    private var memoryBoundMaxConcurrentRequests: Int {
        let budget = tokenBudgetMax
        let averageReserved = averageReservedTokensForAdmission
        guard budget > 0, averageReserved > 0 else { return 1 }
        return max(1, min(maxConcurrentRequests, budget / averageReserved))
    }

    /// Effective concurrency cap reported via `capacity()`. Floor at 1
    /// so a momentary spike in `memoryBoundMaxConcurrentRequests`
    /// doesn't deadlock submission.
    var effectiveMaxConcurrentRequests: Int {
        max(1, min(maxConcurrentRequests, dynamicMaxConcurrentRequests, memoryBoundMaxConcurrentRequests))
    }

    // MARK: - Heartbeat payload

    /// Public surface called from `ProviderLoop` on every heartbeat tick.
    /// Implementation lives in the telemetry extension because most of
    /// the fields are EWMA / queued-budget state owned here.
    public func backendCapacity() async -> BackendCapacity {
        await refreshPendingSummaryCache()
        let cap = capacity()
        let gbDivisor = 1024.0 * 1024.0 * 1024.0

        var activeTokens: Int64 = 0
        var maxTokensPotential: Int64 = 0
        for entry in activeBridges.values {
            activeTokens += Int64(entry.promptTokens + entry.completionTokens)
            maxTokensPotential += Int64(entry.promptTokens + entry.maxTokens)
        }

        let budgetMax = Int64(tokenBudgetMax)

        let slot = BackendSlotCapacity(
            model: cap.model,
            state: cap.activeRequests > 0 ? "running" : "idle",
            numRunning: UInt32(cap.activeRequests),
            numWaiting: UInt32(cap.pendingRequests),
            activeTokens: activeTokens,
            maxTokensPotential: maxTokensPotential,
            maxConcurrency: UInt32(cap.maxConcurrent),
            observedDecodeTps: observedDecodeTpsEwma,
            activeTokenBudgetUsed: Int64(activeTokenBudgetUsed),
            activeTokenBudgetMax: budgetMax,
            queuedTokenBudget: Int64(queuedTokenBudget),
            kvBytesPerToken: Int64(kvBytesPerToken)
        )
        return BackendCapacity(
            slots: [slot],
            gpuMemoryActiveGb: Double(cap.gpuMemoryActiveBytes) / gbDivisor,
            gpuMemoryPeakGb: Double(cap.gpuMemoryPeakBytes) / gbDivisor,
            gpuMemoryCacheGb: Double(cap.gpuMemoryCacheBytes) / gbDivisor,
            totalMemoryGb: Double(cap.totalMemoryBytes) / gbDivisor
        )
    }

    // MARK: - Adaptive cap (TPS-driven)

    /// Update the per-batch-size TPS sample. Called from `recordFinish`.
    /// Drives `updateDynamicMaxConcurrentRequests` which mirrors the
    /// cap into the engine via `setMaxNumSeqs`.
    func recordBatchPerformance(observedBatchSize: Int, tps: Double) {
        guard observedBatchSize > 0, tps > 0 else { return }
        let aggregateTps = tps * Double(observedBatchSize)
        performanceByBatchSize[observedBatchSize, default: AdaptiveBatchPerformanceBucket()]
            .record(aggregateTps: aggregateTps, perRequestTps: tps)
        updateDynamicMaxConcurrentRequests(observedBatchSize: observedBatchSize)
    }

    func updateDynamicMaxConcurrentRequests(observedBatchSize: Int) {
        let next = adaptiveCapPolicy.nextCap(
            currentCap: dynamicMaxConcurrentRequests,
            hardCap: maxConcurrentRequests,
            observedBatchSize: observedBatchSize,
            performanceByBatchSize: performanceByBatchSize
        )
        guard next != dynamicMaxConcurrentRequests else { return }
        dynamicMaxConcurrentRequests = next
        // Mirror to the engine (planner also enforces, ahead of admission).
        engine?.setMaxNumSeqs(next)
    }

    /// EWMA update for `observedDecodeTpsEwma`. Split out of
    /// `recordFinish` so the bridge file isn't entangled with EWMA
    /// math.
    func updateDecodeTpsEwma(tps: Double) {
        let alpha = 0.3
        if ewmaInitialized {
            observedDecodeTpsEwma = alpha * tps + (1 - alpha) * observedDecodeTpsEwma
        } else {
            observedDecodeTpsEwma = tps
            ewmaInitialized = true
        }
    }

    // MARK: - Cached pending-queue summary

    /// Refresh `pendingSummaryCache` from the planner. Called whenever
    /// admission or completion changes the planner pending list.
    func refreshPendingSummaryCache() async {
        guard let planner = self.planner else {
            pendingSummaryCache = .empty
            return
        }
        let snap = await planner.snapshot()
        // Exclude entries that are already in `activeBridges`: their
        // budget is counted under `activeTokenBudgetUsed`, and the
        // planner keeps them in `pendingRequests` until `cancel`.
        // Without this filter the admission gate double-counts.
        let trulyPending = snap.pendingRequests.filter {
            activeBridges[$0.id] == nil
        }
        let queuedTokens = trulyPending.reduce(0) {
            $0 + $1.promptTokenCount + $1.maxOutputTokens
        }
        pendingSummaryCache = PendingSummary(
            queuedRequests: trulyPending.count,
            queuedTokens: queuedTokens
        )
    }

    // MARK: - Misc helpers (small enough to live next to telemetry)

    /// Release the global KV-byte reservation, if any. Called from the
    /// bridge file's recordFinish/dropBridge and from the main file's
    /// cancel/cancelAll/stopCurrentEngine paths.
    func releaseKVReservation(requestID: String) async {
        guard let kvBudget else { return }
        await kvBudget.release(requestID: requestID)
    }

    /// GPU memory read indirection. `private` could compile but
    /// `internal` lets `capacity()` (main file) call it without an
    /// extra hop in extensions.
    func gpuMemory(_ kind: MemoryKind) -> Int {
        #if canImport(Metal)
        switch kind {
        case .active: return MLX.GPU.activeMemory
        case .peak: return MLX.GPU.peakMemory
        case .cache: return MLX.GPU.cacheMemory
        }
        #else
        return 0
        #endif
    }
}
