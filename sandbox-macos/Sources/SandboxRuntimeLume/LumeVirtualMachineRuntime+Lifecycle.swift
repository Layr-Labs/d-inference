import Foundation
import SandboxCore
import SandboxRuntime

extension LumeVirtualMachineRuntime {
    public func stop(name: String) async throws {
        try await stop(name: name, scope: nil)
    }

    func stop(
        name: String,
        scope: SandboxOperationScope?
    ) async throws {
        try await performStop(
            name: name,
            scope: scope
        )
    }

    private func performStop(
        name: String,
        scope: SandboxOperationScope?
    ) async throws {
        guard SandboxVirtualMachineNamePolicy.isValid(name) else {
            throw SandboxRuntimeError.invalidName
        }
        try preauthorize(
            scope: scope,
            operation: .stop,
            virtualMachineName: name
        )
        let operationLock = try beginOperation(
            "stop",
            name: name
        )
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
        let owner = LumeVirtualMachineOwnership.Owner(
            operationScope: scope
        )
        try await stopWithoutOperationFence(
            name: name,
            owner: owner,
            expectedLease: leaseAuthorization?.lease
        )
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

    func waitForState(
        name: String,
        expected: SandboxVirtualMachineState,
        timeoutSeconds: UInt32,
        process: SandboxManagedProcess? = nil
    ) async throws -> SandboxVirtualMachineRecord {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeoutSeconds))
        repeat {
            let observed = try await inspect(name: name)
            if let observed, observed.state == expected {
                return observed
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

    func waitForStoppedOrAbsent(
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
}
