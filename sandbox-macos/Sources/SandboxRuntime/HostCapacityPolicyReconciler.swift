import Foundation

enum SandboxCapacityPolicyReconciler {
    static func adoptExistingPolicy(
        store: SandboxCapacityStateStore,
        policy: SandboxCapacityPolicy,
        adoption: SandboxCapacityPolicyAdoption,
        currentDate: @escaping @Sendable () -> Date,
        availableStorageBytes: @escaping @Sendable () throws -> UInt64
    ) throws {
        _ = try adopt(
            store: store,
            policy: policy,
            adoption: adoption,
            initializeIfMissing: false,
            currentDate: currentDate,
            availableStorageBytes: availableStorageBytes
        )
    }

    static func initialize(
        store: SandboxCapacityStateStore,
        policy: SandboxCapacityPolicy,
        adoption: SandboxCapacityPolicyAdoption,
        currentDate: @escaping @Sendable () -> Date,
        availableStorageBytes: @escaping @Sendable () throws -> UInt64
    ) throws -> SandboxCapacityState {
        guard let state = try adopt(
            store: store,
            policy: policy,
            adoption: adoption,
            initializeIfMissing: true,
            currentDate: currentDate,
            availableStorageBytes: availableStorageBytes
        ) else {
            throw SandboxCapacityError.uninitialized
        }
        return state
    }

    private static func adopt(
        store: SandboxCapacityStateStore,
        policy: SandboxCapacityPolicy,
        adoption: SandboxCapacityPolicyAdoption,
        initializeIfMissing: Bool,
        currentDate: @escaping @Sendable () -> Date,
        availableStorageBytes: @escaping @Sendable () throws -> UInt64
    ) throws -> SandboxCapacityState? {
        let operationLocks = try store.acquireAllLeaseOperationLocks()
        defer { withExtendedLifetime(operationLocks) {} }
        return try store.updatePolicyState(
            requestedPolicy: policy,
            initializeIfMissing: initializeIfMissing
        ) { state in
            if state.effectivePolicy != policy {
                if policy.widensCapacity(comparedTo: state.effectivePolicy) {
                    switch adoption {
                    case .restrictOnly:
                        throw SandboxCapacityError
                            .policyWideningRequiresExplicitAdoption
                    case .allowWidening(let expectedRevision):
                        guard expectedRevision == state.policyRevision else {
                            throw SandboxCapacityError.stalePolicyRevision(
                                expected: expectedRevision,
                                actual: state.policyRevision
                            )
                        }
                        guard state.policyRevision < UInt64.max else {
                            throw SandboxCapacityError.policyRevisionExhausted
                        }
                    }
                }
                state.effectivePolicy = policy
                if state.policyRevision < UInt64.max {
                    state.policyRevision += 1
                }
            }
            if state.mode == .sandboxDedicated,
               (!state.effectivePolicy.accommodates(
                       state.leases,
                       at: currentDate()
                   )
                   || !storageAccommodates(
                       state.leases,
                       policy: state.effectivePolicy,
                       availableStorageBytes: availableStorageBytes
                   ))
            {
                state.mode = .draining
            }
        }
    }

    private static func storageAccommodates(
        _ leases: [SandboxCapacityLease],
        policy: SandboxCapacityPolicy,
        availableStorageBytes: @Sendable () throws -> UInt64
    ) -> Bool {
        var reservedGrowthBytes: UInt64 = 0
        for lease in leases {
            let (sum, overflow) = reservedGrowthBytes
                .addingReportingOverflow(lease.reservedGrowthBytes)
            guard !overflow else {
                return false
            }
            reservedGrowthBytes = sum
        }
        let (requiredBytes, overflow) = reservedGrowthBytes
            .addingReportingOverflow(policy.storageHeadroomBytes)
        guard !overflow,
              let availableBytes = try? availableStorageBytes()
        else {
            return false
        }
        return availableBytes >= requiredBytes
    }
}
