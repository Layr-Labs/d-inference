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
    /// Credentials for this specific guest. `lume ssh` defaults to the shared
    /// `lume`/`lume` pair, which no longer exists on a per-sandbox image.
    let credential: LumeGuestCredential

    package init(
        runner: SandboxProcessRunner,
        executable: URL,
        storagePath: String,
        environment: [String: String],
        credential: LumeGuestCredential = .legacy
    ) {
        self.runner = runner
        self.executable = executable
        self.storagePath = storagePath
        self.environment = environment
        self.credential = credential
    }

    package var description: String { "lume ssh" }

    package func prepare(
        _ request: SandboxGuestCommandRequest
    ) throws -> LumeGuestPreparedCommand {
        LumeGuestPreparedCommand(
            // HOME follows the account this transport authenticates as, or
            // the launchd job writes into a directory the guest does not have.
            payload: .encodedScript(
                try LumeGuestCommandEncoder.encode(
                    request,
                    home: credential.bootstrapHome
                )
            )
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
                "--user", credential.bootstrapUsername,
                encodedCommand,
            ],
            // The password travels here, never in argv: arguments are visible
            // to every process on the host through `ps`.
            environment: environment.merging(
                [
                    LumeGuestCredential.passwordEnvironmentVariable:
                        credential.bootstrapPassword
                ]
            ) { _, credential in credential },
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
