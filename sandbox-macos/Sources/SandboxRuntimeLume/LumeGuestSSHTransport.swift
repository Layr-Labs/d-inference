import Foundation
import SandboxRuntime

/// The launchd bootstrap transport: a base64 zsh script carried in one
/// `lume ssh` argument, authenticated by Lume's shared bootstrap identity.
///
/// This is the default and its behaviour is unchanged — same argv, same
/// timeouts, same errors — so the existing fixtures, which substitute a fake
/// `lume` binary on disk rather than a Swift type, keep working untouched.
///
/// It is also why tenant execution stays disabled: the identity is shared and
/// static, and the guest can rewrite its own launchd metadata.
package struct LumeGuestSSHTransport: LumeGuestCommandTransport {
    /// Lume gets the guest budget plus five seconds to collect the result.
    static let lumeGraceSeconds: UInt32 = 5
    /// The host process gets Lume's budget plus another five.
    static let hostGraceSeconds: UInt32 = 10

    let runner: SandboxProcessRunner
    let executable: URL
    let storagePath: String
    let environment: [String: String]

    package init(
        runner: SandboxProcessRunner,
        executable: URL,
        storagePath: String,
        environment: [String: String]
    ) {
        self.runner = runner
        self.executable = executable
        self.storagePath = storagePath
        self.environment = environment
    }

    package var description: String { "lume ssh" }

    package func prepare(
        _ request: SandboxGuestCommandRequest
    ) throws -> LumeGuestPreparedCommand {
        LumeGuestPreparedCommand(
            payload: .encodedScript(try LumeGuestCommandEncoder.encode(request))
        )
    }

    package func deliver(
        virtualMachineName name: String,
        prepared: LumeGuestPreparedCommand,
        guestTimeoutSeconds: UInt32
    ) async throws -> Data {
        guard case .encodedScript(let encodedCommand) = prepared.payload else {
            throw SandboxRuntimeError.unsupported(
                "the SSH transport was handed a command prepared for another transport"
            )
        }

        let result = try await runner.run(
            executable: executable,
            arguments: [
                "ssh",
                name,
                "--storage", storagePath,
                "--timeout", String(guestTimeoutSeconds + Self.lumeGraceSeconds),
                "--nio-only",
                encodedCommand,
            ],
            environment: environment,
            timeoutSeconds: guestTimeoutSeconds + Self.hostGraceSeconds,
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
                command: description,
                exitCode: result.exitCode,
                stderr: standardError
            )
        }
        return result.standardOutput
    }
}
