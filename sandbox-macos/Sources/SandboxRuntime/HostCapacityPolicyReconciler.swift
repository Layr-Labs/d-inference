enum SandboxCapacityPolicyReconciler {
    static func fenceLeasesOutsidePolicy(
        store: SandboxCapacityStateStore,
        policy: SandboxCapacityPolicy
    ) throws {
        let observed: SandboxCapacityState
        do {
            observed = try store.read()
        } catch SandboxCapacityError.uninitialized {
            // #region agent log
            SandboxCapacityAgentDebugLog.append(
                hypothesisId: "H4",
                location: "HostCapacityPolicyReconciler.swift:10",
                message: "policy adoption returned for uninitialized state",
                data: [
                    "maximumCPU": String(policy.maximumReservedCPUCount),
                    "maximumMemory": String(policy.maximumReservedMemoryBytes),
                    "maximumGrowth": String(policy.maximumReservedGrowthBytes),
                ]
            )
            // #endregion
            return
        }
        let observedAccommodates = accommodates(
            observed.leases,
            policy: policy
        )
        // #region agent log
        SandboxCapacityAgentDebugLog.append(
            hypothesisId: "H1,H5",
            location: "HostCapacityPolicyReconciler.swift:24",
            message: "policy adoption observed durable state",
            data: [
                "accommodates": String(observedAccommodates),
                "leaseCount": String(observed.leases.count),
                "maximumCPU": String(policy.maximumReservedCPUCount),
                "mode": observed.mode.rawValue,
            ]
        )
        // #endregion
        guard observed.mode == .sandboxDedicated,
              !observedAccommodates
        else {
            // #region agent log
            SandboxCapacityAgentDebugLog.append(
                hypothesisId: "H1",
                location: "HostCapacityPolicyReconciler.swift:39",
                message: "policy adoption returned without lease locks",
                data: [
                    "accommodates": String(observedAccommodates),
                    "leaseCount": String(observed.leases.count),
                    "mode": observed.mode.rawValue,
                ]
            )
            // #endregion
            return
        }

        let operationLocks = try store.acquireAllLeaseOperationLocks()
        defer { withExtendedLifetime(operationLocks) {} }
        // #region agent log
        SandboxCapacityAgentDebugLog.append(
            hypothesisId: "H2",
            location: "HostCapacityPolicyReconciler.swift:56",
            message: "policy adoption acquired all lease locks",
            data: ["lockCount": String(operationLocks.count)]
        )
        // #endregion
        try store.update { state in
            let stateAccommodates = accommodates(
                state.leases,
                policy: policy
            )
            // #region agent log
            SandboxCapacityAgentDebugLog.append(
                hypothesisId: "H2",
                location: "HostCapacityPolicyReconciler.swift:68",
                message: "policy adoption rechecked state under lease locks",
                data: [
                    "accommodates": String(stateAccommodates),
                    "leaseCount": String(state.leases.count),
                    "mode": state.mode.rawValue,
                ]
            )
            // #endregion
            guard state.mode == .sandboxDedicated,
                  !stateAccommodates
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
