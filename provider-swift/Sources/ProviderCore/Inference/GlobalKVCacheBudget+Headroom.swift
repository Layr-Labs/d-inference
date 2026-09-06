import Foundation

extension GlobalKVCacheBudget {
    /// One coherent allocator/ownership sample for load and heartbeat readers.
    /// C and C-M have different names so materialized backing is not taxed twice.
    struct HeadroomSnapshot: Sendable {
        let totalBytes: UInt64
        let activeBytes: UInt64
        let cacheBytes: UInt64
        let systemAvailableBytes: UInt64
        let totalOwnedBytes: UInt64
        let unmaterializedCommittedBytes: UInt64
        let activationReserveBytes: UInt64
        let runtimeRemainingBytes: UInt64
        let ownerCount: Int
        let closingOwnerCount: Int
        let materializedBytes: UInt64
        let commitmentDebtBytes: UInt64
        let capBytes: UInt64
        let policyEpoch: UInt64
        let capturedUptimeNanoseconds: UInt64
    }

    nonisolated func memoryHeadroomSnapshot() -> HeadroomSnapshot {
        let capturedAt = DispatchTime.now().uptimeNanoseconds
        let sample = processLedger.snapshot()
        return HeadroomSnapshot(
            totalBytes: physicalMemoryBytes,
            activeBytes: sample.usage.activeBytes, cacheBytes: sample.usage.cacheBytes,
            systemAvailableBytes: sample.usage.systemAvailableBytes,
            totalOwnedBytes: sample.chargedBytes,
            unmaterializedCommittedBytes: sample.unmaterializedBytes,
            activationReserveBytes: sample.policy.reserveBytes,
            runtimeRemainingBytes: sample.remainingBytes,
            ownerCount: sample.ownerCount,
            closingOwnerCount: sample.closingOwnerCount,
            materializedBytes: sample.materializedBytes,
            commitmentDebtBytes: sample.commitmentDebtBytes,
            capBytes: sample.policy.capBytes,
            policyEpoch: sample.policy.epoch,
            capturedUptimeNanoseconds: capturedAt)
    }

    /// Existing load-feasibility view, before activation/minimum-KV headroom.
    /// Feasibility is advisory; claimPendingLoad is the actual atomic permit.
    nonisolated func availableForLoadGb() -> Double {
        let sample = memoryHeadroomSnapshot()
        return ModelLoadAdmission.freeForLoadGb(
            totalBytes: sample.totalBytes,
            systemAvailableBytes: sample.systemAvailableBytes,
            gpuActiveBytes: sample.activeBytes, gpuCacheBytes: sample.cacheBytes,
            reserveBytes: loadReserveBytes,
            outstandingReservationBytes: sample.unmaterializedCommittedBytes)
    }
}
