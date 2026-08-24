import Foundation
import SandboxCore

public struct SandboxHostCapacityArbiter: Sendable {
    private let store: SandboxCapacityStateStore
    private let policy: SandboxCapacityPolicy
    private let currentDate: @Sendable () -> Date
    private let availableStorageBytes: @Sendable () throws -> UInt64
    private let storageIdentity: SandboxStorageVolumeIdentity
    private let reservationPreviewed: (@Sendable () -> Void)?

    public init(
        stateDirectory: URL,
        storageDirectory: URL,
        policy: SandboxCapacityPolicy
    ) throws {
        let inspector = SandboxStorageVolumeInspector()
        let initialReport = try inspector.inspect(path: storageDirectory)
        try self.init(
            stateDirectory: stateDirectory,
            policy: policy,
            storageIdentity: initialReport.identity,
            currentDate: { Date() },
            availableStorageBytes: {
                let report = try inspector.inspect(path: storageDirectory)
                guard report.identity == initialReport.identity else {
                    throw SandboxCapacityError.storageIdentityMismatch
                }
                return report.availableImportantBytes
            }
        )
    }

    package init(
        stateDirectory: URL,
        policy: SandboxCapacityPolicy,
        storageIdentity: SandboxStorageVolumeIdentity? = nil,
        currentDate: @escaping @Sendable () -> Date,
        availableStorageBytes:
            @escaping @Sendable () throws -> UInt64,
        reservationPreviewed: (@Sendable () -> Void)? = nil
    ) throws {
        let identity = storageIdentity ?? SandboxStorageVolumeIdentity(
            canonicalPath: stateDirectory.standardizedFileURL.path
                + "/test-storage",
            device: 0,
            inode: 0
        )
        let store = try SandboxCapacityStateStore(
            stateDirectory: stateDirectory,
            storageIdentity: identity
        )
        try store.validateExistingStateIfPresent()
        try SandboxCapacityPolicyReconciler.fenceLeasesOutsidePolicy(
            store: store,
            policy: policy
        )
        self.store = store
        self.policy = policy
        self.currentDate = currentDate
        self.availableStorageBytes = availableStorageBytes
        self.storageIdentity = identity
        self.reservationPreviewed = reservationPreviewed
    }

    package init(
        stateDirectory: URL,
        policy: SandboxCapacityPolicy,
        storageIdentity: SandboxStorageVolumeIdentity? = nil,
        currentDate: @escaping @Sendable () -> Date,
        availableStorageBytes:
            @escaping @Sendable () throws -> UInt64,
        directorySynchronizationError:
            @escaping @Sendable (Int32) -> Int32?,
        reservationPreviewed: (@Sendable () -> Void)? = nil
    ) throws {
        let identity = storageIdentity ?? SandboxStorageVolumeIdentity(
            canonicalPath: stateDirectory.standardizedFileURL.path
                + "/test-storage",
            device: 0,
            inode: 0
        )
        let store = try SandboxCapacityStateStore(
            stateDirectory: stateDirectory,
            storageIdentity: identity,
            directorySynchronizationError: directorySynchronizationError
        )
        try store.validateExistingStateIfPresent()
        try SandboxCapacityPolicyReconciler.fenceLeasesOutsidePolicy(
            store: store,
            policy: policy
        )
        self.store = store
        self.policy = policy
        self.currentDate = currentDate
        self.availableStorageBytes = availableStorageBytes
        self.storageIdentity = identity
        self.reservationPreviewed = reservationPreviewed
    }

    @discardableResult
    public func initialize() throws -> SandboxCapacitySnapshot {
        let state = try store.initialize(SandboxCapacityState(
            schemaVersion: SandboxCapacityState.schemaVersion,
            mode: .draining,
            nextFencingToken: 1,
            leases: [],
            storageIdentity: storageIdentity
        ))
        return Self.snapshot(from: state)
    }

    public func snapshot() throws -> SandboxCapacitySnapshot {
        Self.snapshot(from: try store.read())
    }

    public func authorize(
        scope: SandboxOperationScope,
        virtualMachineName: String,
        operation: SandboxLeaseOperation,
        resources: SandboxResourceSpecification? = nil,
        bootDiskBytes: UInt64? = nil
    ) throws -> SandboxCapacityLease {
        guard SandboxVirtualMachineNamePolicy.isValid(virtualMachineName) else {
            throw SandboxCapacityError.invalidVirtualMachineName
        }
        return try store.update { state in
            let now = currentDate()
            let index = try Self.leaseIndex(for: scope, in: state.leases)
            let lease = state.leases[index]
            guard lease.scope.fencingToken == scope.fencingToken else {
                throw SandboxCapacityError.staleFencingToken
            }
            guard lease.virtualMachineName == virtualMachineName else {
                throw SandboxCapacityError.leaseVirtualMachineMismatch
            }
            if let resources {
                guard lease.cpuCount == resources.cpuCount,
                      lease.memoryBytes == resources.memoryBytes,
                      lease.workspaceBytes == resources.workspaceBytes
                else {
                    throw SandboxCapacityError.leaseResourceMismatch
                }
            }
            if let bootDiskBytes {
                guard lease.bootDiskBytes == bootDiskBytes else {
                    throw SandboxCapacityError.leaseResourceMismatch
                }
            }
            if operation.requiresActiveLease {
                guard state.mode == .sandboxDedicated else {
                    throw SandboxCapacityError.hostNotAcceptingSandboxes(
                        state.mode
                    )
                }
                guard lease.expiresAt > now else {
                    throw SandboxCapacityError.leaseExpired
                }
            }
            return lease
        }
    }

    package func authorizeMutation(
        scope: SandboxOperationScope,
        virtualMachineName: String,
        operation: SandboxLeaseOperation,
        resources: SandboxResourceSpecification? = nil,
        bootDiskBytes: UInt64? = nil
    ) throws -> SandboxLeaseMutationAuthorization {
        _ = try authorize(
            scope: scope,
            virtualMachineName: virtualMachineName,
            operation: operation,
            resources: resources,
            bootDiskBytes: bootDiskBytes
        )
        let operationLock = try store.acquireLeaseOperationLock(
            sandboxID: scope.sandboxID,
            wait: false
        )
        let lease = try authorize(
            scope: scope,
            virtualMachineName: virtualMachineName,
            operation: operation,
            resources: resources,
            bootDiskBytes: bootDiskBytes
        )
        return SandboxLeaseMutationAuthorization(
            operationLock: operationLock,
            lease: lease
        )
    }

    @discardableResult
    public func setMode(_ mode: SandboxHostMode) throws
        -> SandboxCapacitySnapshot
    {
        return try store.update { state in
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
        bootDiskBytes: UInt64 =
            SandboxDiskPolicy.alpha.bootDiskBytes.lowerBound,
        expiresAt: Date
    ) throws -> SandboxCapacityLease {
        guard SandboxVirtualMachineNamePolicy.isValid(virtualMachineName) else {
            throw SandboxCapacityError.invalidVirtualMachineName
        }
        guard SandboxDiskPolicy.alpha.bootDiskBytes.contains(
            bootDiskBytes
        ) else {
            throw SandboxCapacityError.invalidBootDiskBytes
        }
        let reservedGrowthBytes = try SandboxStorageReservation.growthBytes(
            bootDiskBytes: bootDiskBytes,
            workspaceBytes: resources.workspaceBytes
        )
        var preview = try store.read()
        _ = try reserve(
            in: &preview,
            sandboxID: sandboxID,
            generation: generation,
            virtualMachineName: virtualMachineName,
            resources: resources,
            bootDiskBytes: bootDiskBytes,
            reservedGrowthBytes: reservedGrowthBytes,
            expiresAt: expiresAt
        )
        // #region agent log
        SandboxCapacityAgentDebugLog.append(
            hypothesisId: "H1",
            location: "HostCapacityArbiter.swift:242",
            message: "reservation preview accepted process-local policy",
            data: [
                "leaseCount": String(preview.leases.count),
                "maximumCPU": String(policy.maximumReservedCPUCount),
                "mode": preview.mode.rawValue,
                "requestedCPU": String(resources.cpuCount),
            ]
        )
        // #endregion
        reservationPreviewed?()
        let operationLock = try store.acquireLeaseOperationLock(
            sandboxID: sandboxID
        )
        defer { withExtendedLifetime(operationLock) {} }
        // #region agent log
        SandboxCapacityAgentDebugLog.append(
            hypothesisId: "H2",
            location: "HostCapacityArbiter.swift:258",
            message: "reservation acquired one lease lock",
            data: [
                "maximumCPU": String(policy.maximumReservedCPUCount),
                "requestedCPU": String(resources.cpuCount),
            ]
        )
        // #endregion
        return try store.update { state in
            // #region agent log
            SandboxCapacityAgentDebugLog.append(
                hypothesisId: "H3",
                location: "HostCapacityArbiter.swift:270",
                message: "reservation loaded durable state before commit",
                data: [
                    "leaseCount": String(state.leases.count),
                    "maximumCPU": String(policy.maximumReservedCPUCount),
                    "mode": state.mode.rawValue,
                    "requestedCPU": String(resources.cpuCount),
                ]
            )
            // #endregion
            return try reserve(
                in: &state,
                sandboxID: sandboxID,
                generation: generation,
                virtualMachineName: virtualMachineName,
                resources: resources,
                bootDiskBytes: bootDiskBytes,
                reservedGrowthBytes: reservedGrowthBytes,
                expiresAt: expiresAt
            )
        }
    }

    public func renew(
        scope: SandboxOperationScope,
        expiresAt: Date
    ) throws -> SandboxCapacityLease {
        try requireCurrentScope(scope)
        let operationLock = try store.acquireLeaseOperationLock(
            sandboxID: scope.sandboxID
        )
        defer { withExtendedLifetime(operationLock) {} }
        return try store.update { state in
            let now = currentDate()
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
            let fencingToken = try Self.issueFencingToken(in: &state)
            let renewed = SandboxCapacityLease(
                scope: SandboxOperationScope(
                    sandboxID: existing.scope.sandboxID,
                    generation: existing.scope.generation,
                    fencingToken: fencingToken
                ),
                virtualMachineName: existing.virtualMachineName,
                cpuCount: existing.cpuCount,
                memoryBytes: existing.memoryBytes,
                workspaceBytes: existing.workspaceBytes,
                bootDiskBytes: existing.bootDiskBytes,
                reservedGrowthBytes: existing.reservedGrowthBytes,
                issuedAt: existing.issuedAt,
                expiresAt: expiresAt
            )
            state.leases[index] = renewed
            return renewed
        }
    }

    public func fenceExpiredLease(
        scope: SandboxOperationScope
    ) throws -> SandboxCapacityLease {
        try requireCurrentScope(scope)
        let operationLock = try store.acquireLeaseOperationLock(
            sandboxID: scope.sandboxID
        )
        defer { withExtendedLifetime(operationLock) {} }
        return try store.update { state in
            let index = try Self.leaseIndex(for: scope, in: state.leases)
            let existing = state.leases[index]
            guard existing.scope.fencingToken == scope.fencingToken else {
                throw SandboxCapacityError.staleFencingToken
            }
            guard existing.expiresAt <= currentDate() else {
                throw SandboxCapacityError.leaseNotExpired
            }
            let fenced = SandboxCapacityLease(
                scope: SandboxOperationScope(
                    sandboxID: existing.scope.sandboxID,
                    generation: existing.scope.generation,
                    fencingToken: try Self.issueFencingToken(in: &state)
                ),
                virtualMachineName: existing.virtualMachineName,
                cpuCount: existing.cpuCount,
                memoryBytes: existing.memoryBytes,
                workspaceBytes: existing.workspaceBytes,
                bootDiskBytes: existing.bootDiskBytes,
                reservedGrowthBytes: existing.reservedGrowthBytes,
                issuedAt: existing.issuedAt,
                expiresAt: existing.expiresAt
            )
            state.leases[index] = fenced
            return fenced
        }
    }

    package func release(
        scope: SandboxOperationScope,
        holding authorization: SandboxLeaseMutationAuthorization
    ) throws {
        guard authorization.authorizes(scope) else {
            throw SandboxCapacityError.staleFencingToken
        }
        defer { withExtendedLifetime(authorization) {} }
        try store.update { state in
            try Self.removeLease(scope: scope, from: &state)
        }
    }

    public func expiredLeases() throws -> [SandboxCapacityLease] {
        try store.update { state in
            let now = currentDate()
            return state.leases
                .filter { $0.expiresAt <= now }
                .sorted {
                    $0.scope.fencingToken < $1.scope.fencingToken
                }
        }
    }

    public func validateStorageHeadroom() throws
        -> SandboxStorageCapacitySnapshot
    {
        try store.update { state in
            let reservedGrowth = try state.leases.reduce(UInt64(0)) {
                let (sum, overflow) = $0.addingReportingOverflow(
                    $1.reservedGrowthBytes
                )
                guard !overflow else {
                    throw SandboxCapacityError.corruptState
                }
                return sum
            }
            return try storageCapacitySnapshot(
                reservedGrowthBytes: reservedGrowth
            )
        }
    }

    public func requireStorageDirectory(_ storageDirectory: URL) throws {
        let report: SandboxStorageVolumeReport
        do {
            report = try SandboxStorageVolumeInspector().inspect(
                path: storageDirectory
            )
        } catch {
            throw SandboxCapacityError.storageInspectionFailed
        }
        guard report.identity == storageIdentity else {
            throw SandboxCapacityError.storageIdentityMismatch
        }
    }

    private func requireCurrentScope(_ scope: SandboxOperationScope) throws {
        let state = try store.read()
        let index = try Self.leaseIndex(for: scope, in: state.leases)
        guard state.leases[index].scope.fencingToken == scope.fencingToken else {
            throw SandboxCapacityError.staleFencingToken
        }
    }

    private func reserve(
        in state: inout SandboxCapacityState,
        sandboxID: SandboxID,
        generation: SandboxGeneration,
        virtualMachineName: String,
        resources: SandboxResourceSpecification,
        bootDiskBytes: UInt64,
        reservedGrowthBytes: UInt64,
        expiresAt: Date
    ) throws -> SandboxCapacityLease {
        let now = currentDate()
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
                  existing.memoryBytes == resources.memoryBytes,
                  existing.workspaceBytes == resources.workspaceBytes,
                  existing.bootDiskBytes == bootDiskBytes,
                  existing.reservedGrowthBytes == reservedGrowthBytes
            else {
                throw SandboxCapacityError.staleFencingToken
            }
            return existing
        }
        let generationIndex = state.generationHighWatermarks
            .firstIndex { $0.sandboxID == sandboxID }
        if let generationIndex {
            let highest = state.generationHighWatermarks[
                generationIndex
            ].generation
            guard generation > highest else {
                throw SandboxCapacityError.staleSandboxGeneration(
                    highest: highest,
                    requested: generation
                )
            }
        } else {
            guard state.generationHighWatermarks.count
                    < SandboxCapacityState.maximumGenerationHighWatermarks
            else {
                throw SandboxCapacityError.generationHistoryExhausted
            }
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
        let reservedGrowth = try state.leases.reduce(UInt64(0)) {
            let (sum, overflow) = $0.addingReportingOverflow(
                $1.reservedGrowthBytes
            )
            guard !overflow else {
                throw SandboxCapacityError.corruptState
            }
            return sum
        }
        let (newGrowth, growthOverflow) = reservedGrowth
            .addingReportingOverflow(reservedGrowthBytes)
        guard !growthOverflow,
              newGrowth <= policy.maximumReservedGrowthBytes
        else {
            throw SandboxCapacityError.capacityExhausted
        }
        _ = try storageCapacitySnapshot(reservedGrowthBytes: newGrowth)
        let fencingToken = try Self.issueFencingToken(in: &state)

        let lease = SandboxCapacityLease(
            scope: SandboxOperationScope(
                sandboxID: sandboxID,
                generation: generation,
                fencingToken: fencingToken
            ),
            virtualMachineName: virtualMachineName,
            cpuCount: resources.cpuCount,
            memoryBytes: resources.memoryBytes,
            workspaceBytes: resources.workspaceBytes,
            bootDiskBytes: bootDiskBytes,
            reservedGrowthBytes: reservedGrowthBytes,
            issuedAt: now,
            expiresAt: expiresAt
        )
        if let generationIndex {
            state.generationHighWatermarks[generationIndex].generation =
                generation
        } else {
            state.generationHighWatermarks.append(
                SandboxGenerationHighWatermark(
                    sandboxID: sandboxID,
                    generation: generation
                )
            )
        }
        state.leases.append(lease)
        return lease
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

    private func storageCapacitySnapshot(
        reservedGrowthBytes: UInt64
    ) throws -> SandboxStorageCapacitySnapshot {
        let (neededStorage, overflow) = reservedGrowthBytes
            .addingReportingOverflow(policy.storageHeadroomBytes)
        guard !overflow else {
            throw SandboxCapacityError.capacityExhausted
        }
        let available: UInt64
        do {
            available = try availableStorageBytes()
        } catch let error as SandboxCapacityError {
            throw error
        } catch {
            throw SandboxCapacityError.storageInspectionFailed
        }
        guard available >= neededStorage else {
            throw SandboxCapacityError.insufficientHostStorage(
                needed: neededStorage,
                available: available
            )
        }
        return SandboxStorageCapacitySnapshot(
            reservedGrowthBytes: reservedGrowthBytes,
            storageHeadroomBytes: policy.storageHeadroomBytes,
            availableStorageBytes: available
        )
    }

    private static func issueFencingToken(
        in state: inout SandboxCapacityState
    ) throws -> SandboxFencingToken {
        guard state.nextFencingToken < UInt64.max,
              let fencingToken = SandboxFencingToken(
                  rawValue: state.nextFencingToken
              )
        else {
            throw SandboxCapacityError.fencingTokenExhausted
        }
        state.nextFencingToken += 1
        return fencingToken
    }

    private static func removeLease(
        scope: SandboxOperationScope,
        from state: inout SandboxCapacityState
    ) throws {
        let index = try Self.leaseIndex(for: scope, in: state.leases)
        guard state.leases[index].scope.fencingToken == scope.fencingToken else {
            throw SandboxCapacityError.staleFencingToken
        }
        state.leases.remove(at: index)
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
