import Foundation
import SandboxCore

public struct SandboxHostCapacityArbiter: Sendable {
    private let store: SandboxCapacityStateStore
    private let policy: SandboxCapacityPolicy

    public init(
        stateDirectory: URL,
        policy: SandboxCapacityPolicy
    ) throws {
        self.store = try SandboxCapacityStateStore(
            stateDirectory: stateDirectory
        )
        self.policy = policy
    }

    @discardableResult
    public func initialize() throws -> SandboxCapacitySnapshot {
        let state = try store.initialize(SandboxCapacityState(
            schemaVersion: SandboxCapacityState.schemaVersion,
            mode: .draining,
            nextFencingToken: 1,
            leases: []
        ))
        return Self.snapshot(from: state)
    }

    public func snapshot() throws -> SandboxCapacitySnapshot {
        Self.snapshot(from: try store.read())
    }

    @discardableResult
    public func setMode(_ mode: SandboxHostMode) throws
        -> SandboxCapacitySnapshot
    {
        try store.update { state in
            guard Self.canTransition(
                from: state.mode,
                to: mode,
                leases: state.leases
            ) else {
                throw SandboxCapacityError.invalidModeTransition(
                    from: state.mode,
                    to: mode
                )
            }
            state.mode = mode
            return Self.snapshot(from: state)
        }
    }

    public func reserve(
        sandboxID: SandboxID,
        generation: SandboxGeneration,
        virtualMachineName: String,
        resources: SandboxResourceSpecification,
        expiresAt: Date,
        now: Date = Date()
    ) throws -> SandboxCapacityLease {
        guard SandboxVirtualMachineNamePolicy.isValid(virtualMachineName) else {
            throw SandboxCapacityError.invalidVirtualMachineName
        }
        return try store.update { state in
            guard state.mode == .sandboxDedicated else {
                throw SandboxCapacityError.hostNotAcceptingSandboxes(state.mode)
            }
            try validateDeadline(expiresAt, now: now)

            if let existing = state.leases.first(where: {
                $0.scope.sandboxID == sandboxID
            }) {
                guard existing.scope.generation == generation else {
                    throw SandboxCapacityError.activeSandboxGeneration(
                        existing: existing.scope.generation,
                        requested: generation
                    )
                }
                guard existing.expiresAt > now else {
                    throw SandboxCapacityError.leaseExpired
                }
                guard existing.virtualMachineName == virtualMachineName,
                      existing.cpuCount == resources.cpuCount,
                      existing.memoryBytes == resources.memoryBytes
                else {
                    throw SandboxCapacityError.staleFencingToken
                }
                return existing
            }
            guard !state.leases.contains(where: {
                $0.virtualMachineName == virtualMachineName
            }) else {
                throw SandboxCapacityError.duplicateVirtualMachineName
            }
            guard state.leases.count < policy.maximumRunningSandboxes else {
                throw SandboxCapacityError.capacityExhausted
            }

            let reservedCPU = state.leases.reduce(UInt32(0)) {
                $0 + UInt32($1.cpuCount)
            }
            guard reservedCPU + UInt32(resources.cpuCount)
                    <= UInt32(policy.maximumReservedCPUCount)
            else {
                throw SandboxCapacityError.capacityExhausted
            }
            let reservedMemory = try state.leases.reduce(UInt64(0)) {
                let (sum, overflow) = $0.addingReportingOverflow($1.memoryBytes)
                guard !overflow else {
                    throw SandboxCapacityError.corruptState
                }
                return sum
            }
            let (newMemory, memoryOverflow) = reservedMemory
                .addingReportingOverflow(resources.memoryBytes)
            guard !memoryOverflow,
                  newMemory <= policy.maximumReservedMemoryBytes
            else {
                throw SandboxCapacityError.capacityExhausted
            }
            guard state.nextFencingToken < UInt64.max,
                  let fencingToken = SandboxFencingToken(
                      rawValue: state.nextFencingToken
                  )
            else {
                throw SandboxCapacityError.fencingTokenExhausted
            }
            state.nextFencingToken += 1

            let lease = SandboxCapacityLease(
                scope: SandboxOperationScope(
                    sandboxID: sandboxID,
                    generation: generation,
                    fencingToken: fencingToken
                ),
                virtualMachineName: virtualMachineName,
                cpuCount: resources.cpuCount,
                memoryBytes: resources.memoryBytes,
                issuedAt: now,
                expiresAt: expiresAt
            )
            state.leases.append(lease)
            return lease
        }
    }

    public func renew(
        scope: SandboxOperationScope,
        expiresAt: Date,
        now: Date = Date()
    ) throws -> SandboxCapacityLease {
        try store.update { state in
            guard state.mode == .sandboxDedicated else {
                throw SandboxCapacityError.hostNotAcceptingSandboxes(state.mode)
            }
            try validateDeadline(expiresAt, now: now)
            let index = try Self.leaseIndex(for: scope, in: state.leases)
            let existing = state.leases[index]
            guard existing.scope.fencingToken == scope.fencingToken else {
                throw SandboxCapacityError.staleFencingToken
            }
            guard expiresAt >= existing.expiresAt else {
                throw SandboxCapacityError.invalidLeaseDeadline
            }
            guard existing.expiresAt > now else {
                throw SandboxCapacityError.leaseExpired
            }
            if expiresAt == existing.expiresAt {
                return existing
            }
            guard state.nextFencingToken < UInt64.max,
                  let fencingToken = SandboxFencingToken(
                      rawValue: state.nextFencingToken
                  )
            else {
                throw SandboxCapacityError.fencingTokenExhausted
            }
            state.nextFencingToken += 1
            let renewed = SandboxCapacityLease(
                scope: SandboxOperationScope(
                    sandboxID: existing.scope.sandboxID,
                    generation: existing.scope.generation,
                    fencingToken: fencingToken
                ),
                virtualMachineName: existing.virtualMachineName,
                cpuCount: existing.cpuCount,
                memoryBytes: existing.memoryBytes,
                issuedAt: existing.issuedAt,
                expiresAt: expiresAt
            )
            state.leases[index] = renewed
            return renewed
        }
    }

    public func release(scope: SandboxOperationScope) throws {
        try store.update { state in
            let index = try Self.leaseIndex(for: scope, in: state.leases)
            guard state.leases[index].scope.fencingToken == scope.fencingToken else {
                throw SandboxCapacityError.staleFencingToken
            }
            state.leases.remove(at: index)
        }
    }

    public func expiredLeases(
        at date: Date = Date()
    ) throws -> [SandboxCapacityLease] {
        try snapshot().leases.filter { $0.expiresAt <= date }
    }

    private func validateDeadline(_ expiresAt: Date, now: Date) throws {
        let duration = expiresAt.timeIntervalSince(now)
        guard duration.isFinite,
              duration > 0,
              duration <= policy.maximumLeaseDurationSeconds
        else {
            throw SandboxCapacityError.invalidLeaseDeadline
        }
    }

    private static func leaseIndex(
        for scope: SandboxOperationScope,
        in leases: [SandboxCapacityLease]
    ) throws -> Int {
        if let index = leases.firstIndex(where: {
            $0.scope.sandboxID == scope.sandboxID
                && $0.scope.generation == scope.generation
        }) {
            return index
        }
        if let existing = leases.first(where: {
            $0.scope.sandboxID == scope.sandboxID
        }) {
            throw SandboxCapacityError.activeSandboxGeneration(
                existing: existing.scope.generation,
                requested: scope.generation
            )
        }
        throw SandboxCapacityError.leaseNotFound
    }

    private static func canTransition(
        from: SandboxHostMode,
        to: SandboxHostMode,
        leases: [SandboxCapacityLease]
    ) -> Bool {
        if from == to {
            return true
        }
        switch (from, to) {
        case (.inference, .draining),
             (.sandboxDedicated, .draining):
            return true
        case (.draining, .inference),
             (.draining, .sandboxDedicated):
            return leases.isEmpty
        default:
            return false
        }
    }

    private static func snapshot(
        from state: SandboxCapacityState
    ) -> SandboxCapacitySnapshot {
        SandboxCapacitySnapshot(
            mode: state.mode,
            leases: state.leases.sorted {
                $0.scope.fencingToken < $1.scope.fencingToken
            }
        )
    }
}
