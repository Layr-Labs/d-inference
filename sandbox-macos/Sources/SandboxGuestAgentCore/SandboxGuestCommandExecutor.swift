import Darwin
import Foundation
import SandboxGuestProtocol

/// Runs one guest command and produces the result envelope.
///
/// Thin orchestrator: spawning lives in `SandboxGuestProcessSpawn`, stream
/// capture in `SandboxGuestOutputDrain`.
///
/// The environment policy deliberately mirrors the launchd bootstrap path
/// (`LumeGuestLaunchDefinition`): a fixed deterministic set that wins over
/// caller-supplied values, so a command cannot change its own `PATH`, `HOME`,
/// locale, or `TMPDIR` by passing them in. Both paths must agree, because a
/// command's observable environment should not depend on which transport
/// carried it.
public struct SandboxGuestCommandExecutor: Sendable {
    /// Fixed values that override anything the caller supplies.
    public static func deterministicEnvironment(
        home: String
    ) -> [String: String] {
        [
            "HOME": home,
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": "/tmp",
        ]
    }

    /// Exit code reported when the guest-side deadline fires. Matches the
    /// bootstrap path and the `timedOut ⇒ exitCode == 124` invariant the host
    /// decoder enforces.
    public static let timeoutExitCode: Int32 = 124

    /// Exit code for an agent-side failure that never reached the command.
    static let internalFailureExitCode: Int32 = 70

    public let home: String

    public init(home: String) {
        self.home = home
    }

    public func execute(_ wire: SandboxGuestCommandWire) -> SandboxGuestResultEnvelope {
        guard wire.isWellFormed else {
            return Self.failed(message: "command failed guest-side validation")
        }

        var standardOutput = GuestPipe()
        var standardError = GuestPipe()
        guard standardOutput.open(), standardError.open() else {
            standardOutput.closeAll()
            standardError.closeAll()
            return Self.failed(message: "could not create output pipes")
        }

        let pid: pid_t
        do {
            pid = try SandboxGuestProcessSpawn.spawn(
                executable: wire.executable,
                arguments: [wire.executable] + wire.arguments,
                environment: environment(for: wire),
                workingDirectory: wire.workingDirectory,
                standardOutput: standardOutput.writer,
                standardError: standardError.writer
            )
        } catch {
            standardOutput.closeAll()
            standardError.closeAll()
            return Self.failed(message: "could not spawn command: \(error)")
        }

        // The parent must drop the write ends, or the reads never see EOF.
        standardOutput.closeWriter()
        standardError.closeWriter()

        let supervised = SandboxGuestCommandSupervisor.supervise(
            pid: pid,
            outputDescriptor: standardOutput.reader,
            errorDescriptor: standardError.reader,
            limit: SandboxGuestLimits.maximumStreamBytes,
            deadline: Date().addingTimeInterval(TimeInterval(wire.timeoutSeconds))
        )

        standardOutput.closeReader()
        standardError.closeReader()

        let exitCode: Int32
        if supervised.timedOut {
            exitCode = Self.timeoutExitCode
        } else if let status = supervised.status {
            exitCode = SandboxGuestProcessSpawn.exitCode(from: status)
        } else {
            exitCode = Self.internalFailureExitCode
        }

        return SandboxGuestResultEnvelope(
            exitCode: exitCode,
            standardOutput: supervised.standardOutput.bytes,
            standardError: supervised.standardError.bytes,
            standardOutputTruncated: supervised.standardOutput.truncated,
            standardErrorTruncated: supervised.standardError.truncated,
            timedOut: supervised.timedOut
        )
    }

    private func environment(for wire: SandboxGuestCommandWire) -> [String: String] {
        var environment = Self.deterministicEnvironment(home: home)
        environment.merge(wire.environment) { fixed, _ in fixed }
        environment["DARKBLOOM_IDEMPOTENCY_KEY"] = wire.idempotencyKey
        return environment
    }

    private static func failed(message: String) -> SandboxGuestResultEnvelope {
        SandboxGuestResultEnvelope(
            exitCode: internalFailureExitCode,
            standardOutput: Data(),
            standardError: Data(message.utf8),
            standardOutputTruncated: false,
            standardErrorTruncated: false,
            timedOut: false
        )
    }
}
