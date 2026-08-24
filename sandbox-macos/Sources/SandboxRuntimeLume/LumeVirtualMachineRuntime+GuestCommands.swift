import Foundation
import SandboxCore
import SandboxRuntime

extension LumeVirtualMachineRuntime {
    package func execute(
        name: String,
        request: SandboxGuestCommandRequest
    ) async throws -> SandboxGuestCommandResult {
        try await execute(
            name: name,
            scope: nil,
            request: request
        )
    }

    func execute(
        name: String,
        scope: SandboxOperationScope?,
        request: SandboxGuestCommandRequest
    ) async throws -> SandboxGuestCommandResult {
        guard SandboxVirtualMachineNamePolicy.isValid(name) else {
            throw SandboxRuntimeError.invalidName
        }
        guard case .baseImagePreparationAndDevelopment =
            configuration.guestCommandPolicy
        else {
            throw SandboxRuntimeError.unsupported(
                "guest commands are disabled until the signed guest-control agent is available"
            )
        }
        try preauthorize(
            scope: scope,
            operation: .execute,
            virtualMachineName: name
        )
        let operationLock = try beginOperation("execute", name: name)
        defer {
            endOperation(name: name)
            withExtendedLifetime(operationLock) {}
        }
        let leaseAuthorization = try authorize(
            scope: scope,
            operation: .execute,
            virtualMachineName: name
        )
        defer { withExtendedLifetime(leaseAuthorization) {} }
        let owner = LumeVirtualMachineOwnership.Owner(
            operationScope: scope
        )
        guard let observed = try await inspect(name: name) else {
            throw SandboxRuntimeError.unsupported(
                "guest commands require an existing VM"
            )
        }
        let ownership =
            try LumeVirtualMachineOwnership.requireResourceCommitment(
                name: name,
                owner: owner,
                in: configuration.storageDirectory
            )
        try LumeVirtualMachineResourceCommitment.requireMatch(
            observed: observed,
            ownership: ownership,
            lease: leaseAuthorization?.lease
        )
        let identity = ownership.identity
        let commandJournal = LumeGuestCommandJournal(workspace: workspace)
        switch commandJournal.replay(
            installationID: identity.installationID,
            request: request
        ) {
        case .unclaimed:
            break
        case .indeterminate:
            let unavailable = LumeGuestCommandJournal.outcomeUnavailable()
            try await stopGuestForReplayFailure(
                name: name,
                owner: owner,
                expectedLease: leaseAuthorization?.lease,
                primary: unavailable
            )
            throw unavailable
        case .completed(let replay):
            if replay.timedOut {
                let timeout = SandboxRuntimeError.operationTimedOut(
                    "\(name) guest command"
                )
                try await stopGuestForReplayFailure(
                    name: name,
                    owner: owner,
                    expectedLease: leaseAuthorization?.lease,
                    primary: timeout
                )
                throw timeout
            }
            return replay
        case .conflictingCompleted(let replay):
            let conflict = LumeGuestCommandJournal.idempotencyConflict()
            if replay.timedOut {
                try await stopGuestForReplayFailure(
                    name: name,
                    owner: owner,
                    expectedLease: leaseAuthorization?.lease,
                    primary: conflict
                )
            }
            throw conflict
        }
        var guestCommandMayBeRunning = false
        var requiresVMStop = false
        do {
            let preflight = try await inspect(name: name)
            guard let preflight, preflight.state == .running else {
                throw SandboxRuntimeError.unsupported(
                    "guest commands require a running VM"
                )
            }
            try LumeVirtualMachineResourceCommitment.requireMatch(
                observed: preflight,
                ownership: ownership,
                lease: leaseAuthorization?.lease
            )
            let encodedCommand = try LumeGuestCommandEncoder.encode(request)
            requiresVMStop = true
            let commandClaim = try commandJournal.claim(
                installationID: identity.installationID,
                request: request
            )
            let sshTimeoutSeconds = request.timeoutSeconds + 5
            guestCommandMayBeRunning = true
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
            try commandClaim.complete(envelope: result.standardOutput)
            if decoded.timedOut {
                throw SandboxRuntimeError.operationTimedOut(
                    "\(name) guest command"
                )
            }
            return decoded
        } catch {
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
            let mustStopVM = guestCommandMayBeRunning
                || requiresVMStop
                || executionWasCancelled
                || cancellationFailure != nil
            if mustStopVM {
                do {
                    try await stopGuestIgnoringCancellation(
                        name: name,
                        owner: owner,
                        expectedLease: leaseAuthorization?.lease
                    )
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

    private func stopGuestForReplayFailure(
        name: String,
        owner: LumeVirtualMachineOwnership.Owner,
        expectedLease: SandboxCapacityLease?,
        primary: SandboxRuntimeError
    ) async throws {
        do {
            try await stopGuestIgnoringCancellation(
                name: name,
                owner: owner,
                expectedLease: expectedLease
            )
        } catch {
            throw SandboxRuntimeError.cleanupFailed(
                operation: "reconcile replayed command \(name)",
                primary: String(describing: primary),
                cleanup: "VM stop failed: \(error)"
            )
        }
    }

    private func stopGuestIgnoringCancellation(
        name: String,
        owner: LumeVirtualMachineOwnership.Owner,
        expectedLease: SandboxCapacityLease?
    ) async throws {
        let stop = Task.detached {
            try await self.stopWithoutOperationFence(
                name: name,
                owner: owner,
                expectedLease: expectedLease
            )
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
