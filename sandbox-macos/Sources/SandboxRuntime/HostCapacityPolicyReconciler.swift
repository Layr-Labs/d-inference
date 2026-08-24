enum SandboxCapacityPolicyReconciler {
    static func fenceLeasesOutsidePolicy(
        store: SandboxCapacityStateStore,
        policy: SandboxCapacityPolicy
    ) throws {
        let observed: SandboxCapacityState
        do {
            observed = try store.read()
        } catch SandboxCapacityError.uninitialized {
            return
        }
        guard observed.mode == .sandboxDedicated,
              !accommodates(observed.leases, policy: policy)
        else {
            return
        }

        let operationLocks = try store.acquireAllLeaseOperationLocks()
        defer { withExtendedLifetime(operationLocks) {} }
        try store.update { state in
            guard state.mode == .sandboxDedicated,
                  !accommodates(state.leases, policy: policy)
            else {
                return
            }
            state.mode = .draining
        }
    }

    private static func accommodates(
        _ leases: [SandboxCapacityLease],
        policy: SandboxCapacityPolicy
    ) -> Bool {
        guard leases.count <= policy.maximumRunningSandboxes else {
            return false
        }
        var cpuCount: UInt16 = 0
        var memoryBytes: UInt64 = 0
        var growthBytes: UInt64 = 0
        for lease in leases {
            let (newCPUCount, cpuOverflow) = cpuCount.addingReportingOverflow(
                lease.cpuCount
            )
            let (newMemoryBytes, memoryOverflow) =
                memoryBytes.addingReportingOverflow(lease.memoryBytes)
            let (newGrowthBytes, growthOverflow) =
                growthBytes.addingReportingOverflow(lease.reservedGrowthBytes)
            guard !cpuOverflow,
                  !memoryOverflow,
                  !growthOverflow
            else {
                return false
            }
            cpuCount = newCPUCount
            memoryBytes = newMemoryBytes
            growthBytes = newGrowthBytes
        }
        return cpuCount <= policy.maximumReservedCPUCount
            && memoryBytes <= policy.maximumReservedMemoryBytes
            && growthBytes <= policy.maximumReservedGrowthBytes
    }
}
