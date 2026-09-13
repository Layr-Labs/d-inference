import Foundation
import SandboxCore
import SandboxRuntime

extension LumeVirtualMachineRuntime {
    public func start(name: String) async throws {
        try await start(name: name, scope: nil)
    }

    func start(
        name: String,
        scope: SandboxOperationScope?
    ) async throws {
        guard SandboxVirtualMachineNamePolicy.isValid(name) else {
            throw SandboxRuntimeError.invalidName
        }
        try preauthorize(
            scope: scope,
            operation: .start,
            virtualMachineName: name
        )
        let operationLock = try beginOperation("start", name: name)
        defer {
            endOperation(name: name)
            withExtendedLifetime(operationLock) {}
        }

        let leaseAuthorization = try authorize(
            scope: scope,
            operation: .start,
            virtualMachineName: name
        )
        defer { withExtendedLifetime(leaseAuthorization) {} }
        let owner = LumeVirtualMachineOwnership.Owner(
            operationScope: scope
        )
        guard let existing = try await inspect(name: name) else {
            throw SandboxRuntimeError.unsupported(
                "cannot start missing VM \(name)"
            )
        }
        let ownershipCommitment =
            try LumeVirtualMachineOwnership.requireResourceCommitment(
                name: name,
                owner: owner,
                in: configuration.storageDirectory
            )
        try LumeVirtualMachineResourceCommitment.requireMatch(
            observed: existing,
            ownership: ownershipCommitment,
            lease: leaseAuthorization?.lease
        )
        let ownership = ownershipCommitment.identity
        let startIntent = try LumeVirtualMachineStartIntent.presence(
            name: name,
            ownership: ownership,
            owner: owner,
            in: configuration.storageDirectory
        )
        if existing.state == .running || existing.state == .starting {
            do {
                if let lease = leaseAuthorization?.lease {
                    try await prepareIsolatedGuest(name: name, instanceID: ownership.installationID,
                        workspaceBytes: lease.workspaceBytes, stopped: false)
                }
                let running = existing.state == .running ? existing : try await waitForState(
                    name: name, expected: .running,
                    timeoutSeconds: configuration.commandTimeoutSeconds)
                try LumeVirtualMachineResourceCommitment.requireMatch(
                    observed: running, ownership: ownershipCommitment,
                    lease: leaseAuthorization?.lease)
                try LumeVirtualMachineStartIntent.resolveAfterRunningObserved(
                    startIntent, name: name, ownership: ownership, owner: owner,
                    observedState: .running, in: configuration.storageDirectory)
                try await waitForGuestReady(name: name,
                    timeoutSeconds: configuration.commandTimeoutSeconds)
                return
            } catch {
                // A replay must provide the same terminal cleanup guarantee as
                // a fresh start, including cancellation and missing channels.
                let cleanup = Task.detached {
                    try await self.stopWithoutOperationFence(name: name, owner: owner,
                        expectedLease: leaseAuthorization?.lease)
                }
                do { try await cleanup.value }
                catch let cleanupError {
                    throw SandboxRuntimeError.cleanupFailed(operation: "start \(name)",
                        primary: String(describing: error), cleanup: String(describing: cleanupError))
                }
                throw error
            }
        }
        guard existing.state == .stopped else {
            throw SandboxRuntimeError.unsupported(
                "cannot start VM \(name) while state is \(existing.state.rawValue)"
            )
        }
        try LumeVirtualMachineStartIntent.requireAbsent(
            name: name,
            ownership: ownership,
            owner: owner,
            in: configuration.storageDirectory
        )
        if let lease = leaseAuthorization?.lease {
            try await prepareIsolatedGuest(name: name, instanceID: ownership.installationID,
                workspaceBytes: lease.workspaceBytes, stopped: true)
        }
        let intent = try LumeVirtualMachineStartIntent.persist(
            name: name,
            ownership: ownership,
            owner: owner,
            initiatingScope: scope,
            in: configuration.storageDirectory
        )
        let process: SandboxManagedProcess
        do {
            process = try startManagedRun(name: name, scope: scope)
        } catch {
            do {
                try LumeVirtualMachineStartIntent.clearAfterSpawnFailure(
                    intent,
                    name: name,
                    ownership: ownership,
                    owner: owner,
                    in: configuration.storageDirectory
                )
            } catch let cleanupError {
                throw SandboxRuntimeError.cleanupFailed(
                    operation: "start \(name)",
                    primary: String(describing: error),
                    cleanup: String(describing: cleanupError)
                )
            }
            throw error
        }

        runningProcesses[name] = process
        var unresolvedIntent: LumeVirtualMachineStartIntent.Intent? = intent
        do {
            let running = try await waitForState(
                name: name,
                expected: .running,
                timeoutSeconds: configuration.commandTimeoutSeconds,
                process: process
            )
            try LumeVirtualMachineResourceCommitment.requireMatch(
                observed: running,
                ownership: ownershipCommitment,
                lease: leaseAuthorization?.lease
            )
            try LumeVirtualMachineStartIntent.resolveAfterRunningObserved(
                .unresolved(intent),
                name: name,
                ownership: ownership,
                owner: owner,
                observedState: .running,
                in: configuration.storageDirectory
            )
            unresolvedIntent = nil
            try await waitForGuestReady(
                name: name,
                timeoutSeconds: configuration.commandTimeoutSeconds
            )
        } catch {
            do {
                try await cleanupFailedStartIgnoringCancellation(
                    name: name,
                    owner: owner,
                    ownership: ownershipCommitment,
                    process: process,
                    unresolvedIntent: unresolvedIntent,
                    expectedLease: leaseAuthorization?.lease
                )
            } catch let cleanupError {
                throw SandboxRuntimeError.cleanupFailed(
                    operation: "start \(name)",
                    primary: String(describing: error),
                    cleanup: String(describing: cleanupError)
                )
            }
            throw error
        }
    }

    private func waitForGuestReady(
        name: String,
        timeoutSeconds: UInt32
    ) async throws {
        if configuration.isolatedGuest != nil {
            try await waitForIsolatedGuest(name: name, timeoutSeconds: timeoutSeconds)
            return
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeoutSeconds))
        repeat {
            let record: SandboxVirtualMachineRecord?
            do {
                record = try await LumeGuestReadinessDeadline.run(
                    clock: clock,
                    deadline: deadline
                ) {
                    try await self.inspect(name: name)
                }
            } catch is LumeGuestReadinessDeadlineExceeded {
                break
            }
            if record?.guestReady == true {
                do {
                    if try await LumeCredentialedGuestReadinessProbe.run(
                        runner: processRunner,
                        executable: configuration.executable,
                        storagePath: configuration.storageDirectory.path,
                        environment: workspace.environment,
                        name: name,
                        policy: guestReadinessPolicy,
                        clock: clock,
                        deadline: deadline
                    ) {
                        return
                    }
                } catch let error as CancellationError {
                    throw error
                } catch is LumeGuestReadinessDeadlineExceeded {
                    break
                } catch {
                    if clock.now >= deadline {
                        break
                    }
                }
            }
            guard clock.now < deadline else {
                break
            }
            let retryDeadline = min(
                clock.now.advanced(by: guestReadinessPolicy.retryDelay),
                deadline
            )
            try await clock.sleep(
                until: retryDeadline,
                tolerance: .zero
            )
        } while clock.now < deadline
        throw SandboxRuntimeError.operationTimedOut(
            "\(name) guest readiness"
        )
    }
}
