import Foundation
import SandboxCore
import SandboxRuntime

extension LumeVirtualMachineRuntime {
    public func execute(
        name: String,
        request: SandboxGuestCommandRequest
    ) async throws -> SandboxGuestCommandResult {
        try await execute(
            name: name,
            scope: nil,
            request: request,
            now: Date()
        )
    }

    func execute(
        name: String,
        scope: SandboxOperationScope?,
        request: SandboxGuestCommandRequest,
        now: Date
    ) async throws -> SandboxGuestCommandResult {
        guard SandboxVirtualMachineNamePolicy.isValid(name) else {
            throw SandboxRuntimeError.invalidName
        }
        let operationLock = try beginOperation("execute", name: name)
        defer {
            endOperation(name: name)
            withExtendedLifetime(operationLock) {}
        }
        let leaseAuthorization = try authorize(
            scope: scope,
            operation: .execute,
            virtualMachineName: name,
            now: now
        )
        defer { withExtendedLifetime(leaseAuthorization) {} }
        try LumeVirtualMachineOwnership.requireOwned(
            name: name,
            in: configuration.storageDirectory
        )
        guard try await inspect(name: name)?.state == .running else {
            throw SandboxRuntimeError.unsupported(
                "guest commands require a running VM"
            )
        }
        let encodedCommand = try LumeGuestCommandEncoder.encode(request)
        var requiresVMStop = false
        do {
            let sshTimeoutSeconds = request.timeoutSeconds + 5
            let result = try await processRunner.run(
                executable: configuration.executable,
                arguments: [
                    "ssh",
                    name,
                    "--storage", configuration.storageDirectory.path,
                    "--timeout", String(sshTimeoutSeconds),
                    "--nio-only",
                    encodedCommand,
                ],
                environment: workspace.environment,
                timeoutSeconds: request.timeoutSeconds + 10,
                maximumOutputBytes:
                    LumeGuestCommandEnvelope.maximumEnvelopeBytes
            )
            guard !result.standardOutputTruncated,
                  !result.standardErrorTruncated
            else {
                throw SandboxRuntimeError.malformedOutput(
                    "Lume guest-command output exceeded the capture limit"
                )
            }
            guard result.exitCode == 0 else {
                let standardError = String(
                    decoding: result.standardError,
                    as: UTF8.self
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                throw SandboxRuntimeError.commandFailed(
                    command: "lume ssh",
                    exitCode: result.exitCode,
                    stderr: standardError
                )
            }
            let decoded = try LumeGuestCommandResultDecoder.decode(
                result.standardOutput
            )
            if decoded.timedOut {
                requiresVMStop = true
                throw SandboxRuntimeError.operationTimedOut(
                    "\(name) guest command"
                )
            }
            return decoded
        } catch {
            var cancellationFailure: Error?
            do {
                try await cancelGuestCommandIgnoringCancellation(
                    name: name,
                    idempotencyKey: request.idempotencyKey
                )
            } catch let cleanupError {
                cancellationFailure = cleanupError
            }
            let mustStopVM = requiresVMStop
                || error is CancellationError
                || cancellationFailure != nil
            if mustStopVM {
                do {
                    try await stopGuestIgnoringCancellation(name: name)
                } catch let stopError {
                    throw SandboxRuntimeError.cleanupFailed(
                        operation: "execute \(name)",
                        primary: String(describing: error),
                        cleanup: [
                            cancellationFailure.map {
                                "guest cancellation failed: \($0)"
                            },
                            "VM stop failed: \(stopError)",
                        ].compactMap { $0 }.joined(separator: "; ")
                    )
                }
            }
            if let cancellationFailure {
                throw SandboxRuntimeError.cleanupFailed(
                    operation: "execute \(name)",
                    primary: String(describing: error),
                    cleanup: "guest cancellation failed and VM was stopped: "
                        + String(describing: cancellationFailure)
                )
            }
            throw error
        }
    }

    private func stopGuestIgnoringCancellation(name: String) async throws {
        let stop = Task.detached {
            try await self.stopWithoutOperationFence(name: name)
        }
        try await stop.value
    }

    private func cancelGuestCommandIgnoringCancellation(
        name: String,
        idempotencyKey: UUID
    ) async throws {
        let executable = configuration.executable
        let storagePath = configuration.storageDirectory.path
        let environment = workspace.environment
        let runner = processRunner
        let timeoutSeconds = max(
            UInt32(30),
            min(configuration.commandTimeoutSeconds, UInt32(120))
        )
        let cancellation = LumeGuestCommandEncoder.encodeCancellation(
            idempotencyKey: idempotencyKey
        )
        let cleanup = Task.detached {
            let result = try await runner.run(
                executable: executable,
                arguments: [
                    "ssh",
                    name,
                    "--storage", storagePath,
                    "--timeout", String(timeoutSeconds),
                    "--nio-only",
                    cancellation,
                ],
                environment: environment,
                timeoutSeconds: timeoutSeconds + 10
            )
            guard result.exitCode == 0,
                  !result.standardOutputTruncated,
                  !result.standardErrorTruncated
            else {
                let standardError = String(
                    decoding: result.standardError,
                    as: UTF8.self
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                throw SandboxRuntimeError.commandFailed(
                    command: "lume ssh cancel",
                    exitCode: result.exitCode,
                    stderr: standardError
                )
            }
        }
        try await cleanup.value
    }
}
