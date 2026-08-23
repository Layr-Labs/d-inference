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
        let startedAt = Date()
        // #region agent log
        LumeRuntimeDebugLog.write(
            hypothesisId: "A,B,C",
            location:
                "LumeVirtualMachineRuntime+GuestCommands.swift:execute-entry",
            message: "guest execution started",
            data: [
                "vmRole": LumeRuntimeDebugLog.virtualMachineRole(name),
                "executableRole":
                    LumeRuntimeDebugLog.executableRole(request.executable),
                "requestTimeoutSeconds": String(request.timeoutSeconds),
            ]
        )
        // #endregion
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
        var guestCommandMayBeRunning = false
        var requiresVMStop = false
        do {
            let preflight = try await inspect(name: name)
            guard preflight?.state == .running else {
                throw SandboxRuntimeError.unsupported(
                    "guest commands require a running VM"
                )
            }
            let encodedCommand = try LumeGuestCommandEncoder.encode(request)
            let sshTimeoutSeconds = request.timeoutSeconds + 5
            guestCommandMayBeRunning = true
            // #region agent log
            LumeRuntimeDebugLog.write(
                hypothesisId: "A,B,C",
                location:
                    "LumeVirtualMachineRuntime+GuestCommands.swift:ssh-start",
                message: "Lume SSH guest wrapper started",
                data: [
                    "vmRole": LumeRuntimeDebugLog.virtualMachineRole(name),
                    "executableRole":
                        LumeRuntimeDebugLog.executableRole(request.executable),
                    "preflightState":
                        preflight?.state.rawValue ?? "missing",
                    "preflightGuestReady":
                        String(preflight?.guestReady == true),
                    "lumeTimeoutSeconds": String(sshTimeoutSeconds),
                    "hostTimeoutSeconds":
                        String(request.timeoutSeconds + 10),
                ]
            )
            // #endregion
            let result = try await Self.runGuestSSH(
                runner: processRunner,
                executable: configuration.executable,
                storagePath: configuration.storageDirectory.path,
                environment: workspace.environment,
                name: name,
                encodedCommand: encodedCommand,
                lumeTimeoutSeconds: sshTimeoutSeconds,
                hostTimeoutSeconds: request.timeoutSeconds + 10,
                maximumOutputBytes: LumeGuestCommandEnvelope.maximumEnvelopeBytes
            )
            // #region agent log
            LumeRuntimeDebugLog.write(
                hypothesisId: "A,B",
                location:
                    "LumeVirtualMachineRuntime+GuestCommands.swift:ssh-result",
                message: "Lume SSH guest wrapper completed",
                data: [
                    "vmRole": LumeRuntimeDebugLog.virtualMachineRole(name),
                    "executableRole":
                        LumeRuntimeDebugLog.executableRole(request.executable),
                    "elapsedMilliseconds": String(
                        Int(Date().timeIntervalSince(startedAt) * 1_000)
                    ),
                    "exitCode": String(result.exitCode),
                    "stdoutBytes": String(result.standardOutput.count),
                    "stderrBytes": String(result.standardError.count),
                ]
            )
            // #endregion
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
            // #region agent log
            LumeRuntimeDebugLog.write(
                hypothesisId: "A,B,C",
                location:
                    "LumeVirtualMachineRuntime+GuestCommands.swift:execute-error",
                message: "guest execution entered cleanup",
                data: LumeRuntimeDebugLog.errorData(error).merging([
                    "vmRole": LumeRuntimeDebugLog.virtualMachineRole(name),
                    "executableRole":
                        LumeRuntimeDebugLog.executableRole(request.executable),
                    "elapsedMilliseconds": String(
                        Int(Date().timeIntervalSince(startedAt) * 1_000)
                    ),
                    "guestCommandMayBeRunning":
                        String(guestCommandMayBeRunning),
                ]) { _, observation in observation }
            )
            // #endregion
            let executionWasCancelled =
                Task.isCancelled || error is CancellationError
            var cancellationFailure: Error?
            if guestCommandMayBeRunning {
                do {
                    try await cancelGuestCommandIgnoringCancellation(
                        name: name,
                        idempotencyKey: request.idempotencyKey
                    )
                } catch let cleanupError {
                    cancellationFailure = cleanupError
                }
            }
            let mustStopVM = requiresVMStop
                || executionWasCancelled
                || cancellationFailure != nil
            // #region agent log
            LumeRuntimeDebugLog.write(
                hypothesisId: "B,C",
                location:
                    "LumeVirtualMachineRuntime+GuestCommands.swift:cleanup-decision",
                message: "guest execution cleanup decision made",
                data: [
                    "vmRole": LumeRuntimeDebugLog.virtualMachineRole(name),
                    "executableRole":
                        LumeRuntimeDebugLog.executableRole(request.executable),
                    "executionWasCancelled":
                        String(executionWasCancelled),
                    "guestCancellationFailed":
                        String(cancellationFailure != nil),
                    "requiresVMStop": String(requiresVMStop),
                    "mustStopVM": String(mustStopVM),
                ]
            )
            // #endregion
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
            let result = try await Self.runGuestSSH(
                runner: runner,
                executable: executable,
                storagePath: storagePath,
                environment: environment,
                name: name,
                encodedCommand: cancellation,
                lumeTimeoutSeconds: timeoutSeconds,
                hostTimeoutSeconds: timeoutSeconds + 10,
                maximumOutputBytes:
                    SandboxProcessRunner.defaultMaximumOutputBytes
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

    private static func runGuestSSH(
        runner: SandboxProcessRunner,
        executable: URL,
        storagePath: String,
        environment: [String: String],
        name: String,
        encodedCommand: String,
        lumeTimeoutSeconds: UInt32,
        hostTimeoutSeconds: UInt32,
        maximumOutputBytes: Int
    ) async throws -> SandboxProcessResult {
        try await runner.run(
            executable: executable,
            arguments: [
                "ssh",
                name,
                "--storage", storagePath,
                "--timeout", String(lumeTimeoutSeconds),
                "--nio-only",
                encodedCommand,
            ],
            environment: environment,
            timeoutSeconds: hostTimeoutSeconds,
            maximumOutputBytes: maximumOutputBytes
        )
    }
}
