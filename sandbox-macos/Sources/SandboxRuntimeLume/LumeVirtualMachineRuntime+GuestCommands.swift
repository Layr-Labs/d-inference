import Foundation
import SandboxRuntime

extension LumeVirtualMachineRuntime {
    public func execute(
        name: String,
        request: SandboxGuestCommandRequest
    ) async throws -> SandboxGuestCommandResult {
        guard SandboxVirtualMachineNamePolicy.isValid(name) else {
            throw SandboxRuntimeError.invalidName
        }
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
        do {
            let result = try await processRunner.run(
                executable: configuration.executable,
                arguments: [
                    "ssh",
                    name,
                    "--storage", configuration.storageDirectory.path,
                    "--timeout", String(request.timeoutSeconds),
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
            return try LumeGuestCommandResultDecoder.decode(
                result.standardOutput
            )
        } catch {
            do {
                try await cancelGuestCommandIgnoringCancellation(
                    name: name,
                    idempotencyKey: request.idempotencyKey
                )
            } catch let cleanupError {
                throw SandboxRuntimeError.cleanupFailed(
                    operation: "execute \(name)",
                    primary: String(describing: error),
                    cleanup: String(describing: cleanupError)
                )
            }
            throw error
        }
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
