import Foundation
import SandboxCore
import SandboxRuntime

extension LumeVirtualMachineRuntime {
    public func create(
        _ specification: SandboxVirtualMachineSpecification
    ) async throws {
        try await create(specification, scope: nil)
    }

    func create(
        _ specification: SandboxVirtualMachineSpecification,
        scope: SandboxOperationScope?
    ) async throws {
        let operationLock = try beginOperation(
            "create",
            name: specification.name
        )
        defer {
            endOperation(name: specification.name)
            withExtendedLifetime(operationLock) {}
        }

        let leaseAuthorization = try authorize(
            scope: scope,
            operation: .create,
            virtualMachineName: specification.name,
            resources: specification.resources
        )
        defer { withExtendedLifetime(leaseAuthorization) {} }
        _ = try await validateRuntime()
        try ensureStorageDirectory()
        if let existing = try await inspect(name: specification.name) {
            guard Self.matches(existing, specification: specification),
                  LumeVirtualMachineOwnership.matches(
                      specification: specification,
                      in: configuration.storageDirectory
                  )
            else {
                throw SandboxRuntimeError.unsupported(
                    "VM \(specification.name) already exists without matching Darkbloom ownership"
                )
            }
            return
        }

        var sourceOperationName: String?
        var sourceOperationLock: LumeVirtualMachineOperationLock?
        if case .localTemplate(let template) = specification.imageSource {
            guard template != specification.name else {
                throw SandboxRuntimeError.invalidImageReference
            }
            sourceOperationLock = try beginOperation(
                "clone-source",
                name: template
            )
            sourceOperationName = template
        }
        defer {
            if let sourceOperationName {
                endOperation(name: sourceOperationName)
            }
            withExtendedLifetime(sourceOperationLock) {}
        }

        let arguments: [String]
        switch specification.imageSource {
        case .restoreImage(let url, let unattendedPreset):
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                throw SandboxRuntimeError.invalidImageReference
            }
            arguments = storageArguments([
                "create",
                specification.name,
                "--os", "macOS",
                "--cpu", String(specification.resources.cpuCount),
                "--memory", "\(specification.resources.memoryBytes)B",
                "--disk-size", "\(specification.diskBytes)B",
                "--ipsw", url.path,
                "--unattended", unattendedPreset,
                "--no-display",
                "--vnc-port", "0",
                "--network", "nat",
            ])
        case .localTemplate(let template):
            guard try await inspect(name: template) != nil else {
                throw SandboxRuntimeError.invalidImageReference
            }
            try LumeVirtualMachineOwnership.requireOwned(
                name: template,
                in: configuration.storageDirectory
            )
            arguments = [
                "clone",
                template,
                specification.name,
                "--source-storage", configuration.storageDirectory.path,
                "--dest-storage", configuration.storageDirectory.path,
            ]
        }
        let creationWorkspace = try workspace.makeCreationWorkspace(
            name: specification.name
        )

        do {
            _ = try await run(
                arguments: arguments,
                timeoutSeconds: configuration.createTimeoutSeconds,
                operation: "create",
                environment: creationWorkspace.environment
            )
            guard let created = try await inspect(name: specification.name),
                  created.state == .stopped,
                  Self.matches(created, specification: specification)
            else {
                throw SandboxRuntimeError.malformedOutput(
                    "Lume create completed without the requested stopped VM"
                )
            }
            try LumeVirtualMachineOwnership.write(
                specification: specification,
                to: creationWorkspace.destination
            )
        } catch {
            do {
                try await cleanupFailedCreationIgnoringCancellation(
                    workspace: creationWorkspace
                )
            } catch let cleanupError {
                throw SandboxRuntimeError.cleanupFailed(
                    operation: "create \(specification.name)",
                    primary: String(describing: error),
                    cleanup: String(describing: cleanupError)
                )
            }
            throw error
        }
        do {
            try await cleanupCreationScratchIgnoringCancellation(
                workspace: creationWorkspace
            )
        } catch {
            throw SandboxRuntimeError.cleanupFailed(
                operation: "finish create \(specification.name)",
                primary: "virtual machine creation completed",
                cleanup: String(describing: error)
            )
        }
    }

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
        guard let existing = try await inspect(name: name) else {
            throw SandboxRuntimeError.unsupported(
                "cannot start missing VM \(name)"
            )
        }
        try LumeVirtualMachineOwnership.requireOwned(
            name: name,
            in: configuration.storageDirectory
        )
        if existing.state == .running {
            try await waitForGuestReady(
                name: name,
                timeoutSeconds: configuration.commandTimeoutSeconds
            )
            return
        }
        if existing.state == .starting {
            try await waitForState(
                name: name,
                expected: .running,
                timeoutSeconds: configuration.commandTimeoutSeconds
            )
            try await waitForGuestReady(
                name: name,
                timeoutSeconds: configuration.commandTimeoutSeconds
            )
            return
        }
        guard existing.state == .stopped else {
            throw SandboxRuntimeError.unsupported(
                "cannot start VM \(name) while state is \(existing.state.rawValue)"
            )
        }

        do {
            let process = try processRunner.start(
                executable: configuration.executable,
                arguments: storageArguments([
                    "run",
                    name,
                    "--display", "none",
                    "--vnc", "disabled",
                ]),
                environment: workspace.environment
            )
            runningProcesses[name] = process
            try await waitForState(
                name: name,
                expected: .running,
                timeoutSeconds: configuration.commandTimeoutSeconds,
                process: process
            )
            try await waitForGuestReady(
                name: name,
                timeoutSeconds: configuration.commandTimeoutSeconds
            )
        } catch {
            do {
                try await cleanupFailedStartIgnoringCancellation(name: name)
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

    public func stop(name: String) async throws {
        try await stop(name: name, scope: nil)
    }

    func stop(
        name: String,
        scope: SandboxOperationScope?
    ) async throws {
        guard SandboxVirtualMachineNamePolicy.isValid(name) else {
            throw SandboxRuntimeError.invalidName
        }
        let operationLock = try beginOperation("stop", name: name)
        defer {
            endOperation(name: name)
            withExtendedLifetime(operationLock) {}
        }
        let leaseAuthorization = try authorize(
            scope: scope,
            operation: .stop,
            virtualMachineName: name
        )
        defer { withExtendedLifetime(leaseAuthorization) {} }
        try await stopWithoutOperationFence(name: name)
    }

    public func delete(name: String) async throws {
        try await delete(name: name, scope: nil)
    }

    func delete(
        name: String,
        scope: SandboxOperationScope?
    ) async throws {
        guard SandboxVirtualMachineNamePolicy.isValid(name) else {
            throw SandboxRuntimeError.invalidName
        }
        let operationLock = try beginOperation("delete", name: name)
        defer {
            endOperation(name: name)
            withExtendedLifetime(operationLock) {}
        }

        let leaseAuthorization = try authorize(
            scope: scope,
            operation: .delete,
            virtualMachineName: name
        )
        defer { withExtendedLifetime(leaseAuthorization) {} }
        guard let existing = try await inspect(name: name) else {
            return
        }
        try LumeVirtualMachineOwnership.requireOwned(
            name: name,
            in: configuration.storageDirectory
        )
        guard existing.state == .stopped || existing.state == .failed else {
            throw SandboxRuntimeError.unsupported(
                "refusing to delete VM \(name) while state is \(existing.state.rawValue)"
            )
        }
        _ = try await run(
            arguments: storageArguments(["delete", name, "--force"]),
            timeoutSeconds: configuration.commandTimeoutSeconds,
            operation: "delete"
        )
        guard try await inspect(name: name) == nil else {
            throw SandboxRuntimeError.malformedOutput(
                "Lume delete completed but VM still exists"
            )
        }
    }

    func beginOperation(
        _ operation: String,
        name: String
    ) throws -> LumeVirtualMachineOperationLock {
        if let activeOperation = activeOperations[name] {
            throw SandboxRuntimeError.operationInProgress(
                name: name,
                operation: activeOperation
            )
        }
        let lock = try LumeVirtualMachineOperationLock(
            workspace: workspace,
            name: name,
            operation: operation
        )
        activeOperations[name] = operation
        return lock
    }

    func endOperation(name: String) {
        activeOperations.removeValue(forKey: name)
    }

    private func cleanupFailedStartIgnoringCancellation(
        name: String
    ) async throws {
        let process = runningProcesses.removeValue(forKey: name)
        let cleanup = Task.detached {
            try await self.cleanupFailedStart(
                name: name,
                process: process
            )
        }
        try await cleanup.value
    }

    private func cleanupFailedStart(
        name: String,
        process: SandboxManagedProcess?
    ) async throws {
        if let process {
            _ = await process.stop()
        }
        let state = try await inspect(name: name)?.state
        if state != nil && state != .stopped {
            _ = try await run(
                arguments: storageArguments(["stop", name]),
                timeoutSeconds: configuration.commandTimeoutSeconds,
                operation: "cleanup stop"
            )
        }
        try await waitForStoppedOrAbsent(
            name: name,
            timeoutSeconds: configuration.commandTimeoutSeconds
        )
    }

    private func cleanupFailedCreationIgnoringCancellation(
        workspace: LumeCreationWorkspace
    ) async throws {
        let cleanup = Task.detached {
            try await workspace.removeAllArtifacts()
        }
        try await cleanup.value
    }

    private func cleanupCreationScratchIgnoringCancellation(
        workspace: LumeCreationWorkspace
    ) async throws {
        let cleanup = Task.detached {
            try await workspace.removeScratch()
        }
        try await cleanup.value
    }

    func stopWithoutOperationFence(name: String) async throws {
        guard let existing = try await inspect(name: name) else {
            if let process = runningProcesses.removeValue(forKey: name) {
                _ = await process.stop()
            }
            return
        }
        try LumeVirtualMachineOwnership.requireOwned(
            name: name,
            in: configuration.storageDirectory
        )
        if existing.state == .stopped {
            if let process = runningProcesses.removeValue(forKey: name) {
                _ = await process.stop()
            }
            return
        }
        _ = try await run(
            arguments: storageArguments(["stop", name]),
            timeoutSeconds: configuration.commandTimeoutSeconds,
            operation: "stop"
        )
        try await waitForStoppedOrAbsent(
            name: name,
            timeoutSeconds: configuration.commandTimeoutSeconds
        )
        if let process = runningProcesses.removeValue(forKey: name) {
            _ = await process.stop()
        }
    }

    private func waitForState(
        name: String,
        expected: SandboxVirtualMachineState,
        timeoutSeconds: UInt32,
        process: SandboxManagedProcess? = nil
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeoutSeconds))
        repeat {
            if try await inspect(name: name)?.state == expected {
                return
            }
            if let process, !process.isRunning {
                let result = await process.wait()
                runningProcesses.removeValue(forKey: name)
                let standardError = String(
                    decoding: result.standardError,
                    as: UTF8.self
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                throw SandboxRuntimeError.commandFailed(
                    command: "lume start",
                    exitCode: result.exitCode,
                    stderr: standardError
                )
            }
            try await Task.sleep(for: .milliseconds(250))
        } while clock.now < deadline
        throw SandboxRuntimeError.operationTimedOut(
            "\(name) -> \(expected.rawValue)"
        )
    }

    private func waitForStoppedOrAbsent(
        name: String,
        timeoutSeconds: UInt32
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeoutSeconds))
        repeat {
            let state = try await inspect(name: name)?.state
            if state == nil || state == .stopped {
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        } while clock.now < deadline
        throw SandboxRuntimeError.operationTimedOut(
            "\(name) -> stopped"
        )
    }

    private func waitForGuestReady(
        name: String,
        timeoutSeconds: UInt32
    ) async throws {
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
                    if try await LumeGuestReadinessProbe.run(
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

    private static func matches(
        _ record: SandboxVirtualMachineRecord,
        specification: SandboxVirtualMachineSpecification
    ) -> Bool {
        record.cpuCount == specification.resources.cpuCount
            && record.memoryBytes == specification.resources.memoryBytes
            && record.diskBytes == specification.diskBytes
    }
}
