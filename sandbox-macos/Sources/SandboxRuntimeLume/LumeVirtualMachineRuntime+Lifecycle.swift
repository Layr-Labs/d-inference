import Foundation
import SandboxCore
import SandboxRuntime

extension LumeVirtualMachineRuntime {
    public func create(
        _ specification: SandboxVirtualMachineSpecification
    ) async throws {
        try beginOperation("create", name: specification.name)
        defer { endOperation(name: specification.name) }

        _ = try await validateRuntime()
        try ensureStorageDirectory()
        if let existing = try await inspect(name: specification.name) {
            guard Self.matches(existing, specification: specification) else {
                throw SandboxRuntimeError.unsupported(
                    "VM \(specification.name) already exists with different resources"
                )
            }
            return
        }
        let creationWorkspace = try workspace.makeCreationWorkspace(
            name: specification.name
        )

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
            arguments = [
                "clone",
                template,
                specification.name,
                "--source-storage", configuration.storageDirectory.path,
                "--dest-storage", configuration.storageDirectory.path,
            ]
        }

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
        guard SandboxVirtualMachineNamePolicy.isValid(name) else {
            throw SandboxRuntimeError.invalidName
        }
        try beginOperation("start", name: name)
        defer { endOperation(name: name) }

        guard let existing = try await inspect(name: name) else {
            throw SandboxRuntimeError.unsupported(
                "cannot start missing VM \(name)"
            )
        }
        if existing.state == .running {
            if existing.guestReady != true {
                try await waitForGuestReady(
                    name: name,
                    timeoutSeconds: configuration.commandTimeoutSeconds
                )
            }
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
            _ = try await run(
                arguments: storageArguments([
                    "run",
                    name,
                    "--detach",
                    "--display", "none",
                    "--vnc", "disabled",
                ]),
                timeoutSeconds: configuration.commandTimeoutSeconds,
                operation: "start"
            )
            try await waitForState(
                name: name,
                expected: .running,
                timeoutSeconds: configuration.commandTimeoutSeconds
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
        guard SandboxVirtualMachineNamePolicy.isValid(name) else {
            throw SandboxRuntimeError.invalidName
        }
        try beginOperation("stop", name: name)
        defer { endOperation(name: name) }
        try await stopWithoutOperationFence(name: name)
    }

    public func delete(name: String) async throws {
        guard SandboxVirtualMachineNamePolicy.isValid(name) else {
            throw SandboxRuntimeError.invalidName
        }
        try beginOperation("delete", name: name)
        defer { endOperation(name: name) }

        guard let existing = try await inspect(name: name) else {
            return
        }
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

    private func beginOperation(_ operation: String, name: String) throws {
        if let activeOperation = activeOperations[name] {
            throw SandboxRuntimeError.operationInProgress(
                name: name,
                operation: activeOperation
            )
        }
        activeOperations[name] = operation
    }

    private func endOperation(name: String) {
        activeOperations.removeValue(forKey: name)
    }

    private func cleanupFailedStartIgnoringCancellation(
        name: String
    ) async throws {
        let cleanup = Task.detached {
            try await self.stopWithoutOperationFence(name: name)
        }
        try await cleanup.value
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

    private func stopWithoutOperationFence(name: String) async throws {
        guard let existing = try await inspect(name: name) else {
            return
        }
        if existing.state == .stopped {
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
    }

    private func waitForState(
        name: String,
        expected: SandboxVirtualMachineState,
        timeoutSeconds: UInt32
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeoutSeconds))
        repeat {
            if try await inspect(name: name)?.state == expected {
                return
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
            if try await inspect(name: name)?.guestReady == true {
                return
            }
            try await Task.sleep(for: .milliseconds(500))
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
