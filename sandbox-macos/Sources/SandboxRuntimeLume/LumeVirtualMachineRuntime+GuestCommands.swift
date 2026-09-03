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
        guard configuration.guestCommandPolicy.permitsGuestCommands else {
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
        let ownership =
            try LumeVirtualMachineOwnership.requireResourceCommitment(
                name: name,
                owner: owner,
                in: configuration.storageDirectory
            )
        // An image built before patch 0006 still carries the shared lume/lume
        // account, which can rewrite the launchd metadata supervising its own
        // commands -- the exact weakness per-sandbox identities were introduced
        // to close. The flag has existed since then and was read nowhere, so a
        // stale template would have been executed against silently.
        guard !ownership.guestCredential.isLegacyShared else {
            throw SandboxRuntimeError.unsupported(
                "guest commands require a per-sandbox credential; this image "
                    + "predates them and still carries the shared account"
            )
        }
        let identity = ownership.identity
        let commandJournal = LumeGuestCommandJournal(workspace: workspace)
        var guestCommandMayBeRunning = false
        var requiresVMStop = false
        /// Whether the command went over the agent channel rather than SSH.
        /// Cancellation is only meaningful on the SSH path; see the catch.
        var deliveredOverChannel = false
        do {
            guard let observed = try await inspect(name: name) else {
                throw SandboxRuntimeError.unsupported(
                    "guest commands require an existing VM"
                )
            }
            try LumeVirtualMachineResourceCommitment.requireMatch(
                observed: observed,
                ownership: ownership,
                lease: leaseAuthorization?.lease
            )
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
            guard observed.state == .running else {
                throw SandboxRuntimeError.unsupported(
                    "guest commands require a running VM"
                )
            }
            // Encode before the durable claim: a request that cannot be
            // prepared must not leave an unresolvable claim in the journal.
            let transport = guestCommandTransport(
                name: name,
                credential: ownership.guestCredential
            )
            deliveredOverChannel = transport is LumeGuestVsockTransport
            let prepared = try transport.prepare(request)
            requiresVMStop = true
            let commandClaim = try commandJournal.claim(
                installationID: identity.installationID,
                request: request
            )
            guestCommandMayBeRunning = true
            let envelope = try await transport.deliver(
                virtualMachineName: name,
                prepared: prepared,
                guestTimeoutSeconds: request.timeoutSeconds
            )
            let decoded = try LumeGuestCommandResultDecoder.decode(envelope)
            try commandClaim.complete(envelope: envelope)
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
            // Cancellation boots out a launchd job by label, which only the
            // SSH path ever creates: the agent spawns the command itself with
            // posix_spawn, under no label. Running it for a channel-delivered
            // command would boot out a job that never existed, fail, and --
            // because a cancellation failure forces `mustStopVM` and is
            // rewrapped as `cleanupFailed` below -- turn a recoverable command
            // failure into a VM teardown reported as a cleanup fault.
            //
            // Skipping it loses nothing that matters. The guest-side deadline
            // still kills the process group and reports `timedOut` on its own,
            // and `guestCommandMayBeRunning` already forces the VM stop just
            // below, which ends the command with the machine it runs on. A
            // cancel frame in the protocol is the real fix and belongs in its
            // own change.
            if guestCommandMayBeRunning && !deliveredOverChannel {
                do {
                    try await cancelGuestCommandIgnoringCancellation(
                        name: name,
                        idempotencyKey: request.idempotencyKey,
                        credential: ownership.guestCredential
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
        idempotencyKey: UUID,
        credential: LumeGuestCredential
    ) async throws {
        let executable = configuration.executable
        let storagePath = configuration.storageDirectory.path
        let environment = workspace.environment
        let runner = processRunner
        let timeoutSeconds = max(
            UInt32(30),
            min(configuration.commandTimeoutSeconds, UInt32(120))
        )
        // The same control root the execution script wrote into, which is the
        // bootstrap account's home and not the shared account's.
        let cancellation = LumeGuestCommandEncoder.encodeCancellation(
            idempotencyKey: idempotencyKey,
            home: credential.bootstrapHome
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

    /// Runs a raw `lume ssh` invocation.
    ///
    /// Only cancellation uses this now. Cancellation is inherently
    /// transport-specific — it boots out a launchd job by label — and the
    /// agent protocol has no cancel frame yet, so it stays on the bootstrap
    /// path rather than being forced through the transport seam.
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

    /// The transport this runtime delivers guest commands over.
    ///
    /// SSH stays the default. The vsock transport is selected per sandbox once
    /// a guest channel has been handed over, and cannot be until the signed
    /// agent is baked into the image.
    /// Adds the guest administrator password to a child environment.
    ///
    /// It travels in the environment rather than argv because command-line
    /// arguments are visible to every process on the host through `ps`, and
    /// this is the guest's administrator credential.
    static func environment(
        _ base: [String: String],
        credential: LumeGuestCredential?
    ) -> [String: String] {
        guard let credential else { return base }
        var environment = base
        environment[LumeGuestCredential.passwordEnvironmentVariable] =
            credential.bootstrapPassword
        return environment
    }

    /// Picks the delivery path for one command.
    ///
    /// A VM has a channel only if this process spawned it and the image's
    /// baked agent bound its port, so absence is the ordinary case and SSH
    /// stays the fallback rather than an error path. Selection is optimistic:
    /// a stored client says nothing about whether the descriptor is still
    /// connected, and the only signal of a dead channel is a failed command,
    /// which `execute`'s existing error handling already treats as fatal to
    /// the VM.
    func guestCommandTransport(
        name: String,
        credential: LumeGuestCredential
    ) -> any LumeGuestCommandTransport {
        // A channel is necessary but not sufficient. The agent gates its own
        // executor, so routing to a channel whose peer refuses everything
        // would turn a working operator path into a per-command refusal --
        // which is exactly what it did once adoption started succeeding.
        if guestChannelServesCommands(name), let channel = guestChannel(for: name) {
            return LumeGuestVsockTransport(channel: channel)
        }
        return LumeGuestSSHTransport(
            runner: processRunner,
            executable: configuration.executable,
            storagePath: configuration.storageDirectory.path,
            environment: workspace.environment,
            credential: credential
        )
    }
}
