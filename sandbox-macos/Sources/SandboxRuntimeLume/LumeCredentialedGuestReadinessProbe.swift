import Foundation
import SandboxRuntime

package struct LumeGuestReadinessPolicy: Sendable {
    // Exercise the launchd-backed bootstrap wrapper. The probe gets the same
    // 35-second Lume budget as a 30-second guest command, plus five seconds for
    // the host process to collect Lume's result.
    package static let standard = LumeGuestReadinessPolicy(
        attemptTimeoutSeconds: 40,
        retryDelay: .milliseconds(500)
    )

    let attemptTimeoutSeconds: UInt32
    let retryDelay: Duration

    package init(
        attemptTimeoutSeconds: UInt32,
        retryDelay: Duration
    ) {
        precondition(attemptTimeoutSeconds > 0)
        precondition(retryDelay > .zero)
        self.attemptTimeoutSeconds = attemptTimeoutSeconds
        self.retryDelay = retryDelay
    }
}

enum LumeCredentialedGuestReadinessProbe {
    /// The guest-side deadline for the probe's `/usr/bin/true`.
    ///
    /// This was 1 second, which made the probe measure load rather than
    /// readiness. A guest one minute out of a fresh macOS install sits at a
    /// load average around 60, and the wrapper's `/usr/bin/true` is spawned but
    /// killed before it finishes, which the envelope reports as `124` and
    /// `timed_out` -- indistinguishable from a broken executor. Measured on the
    /// same VM: at load 60 the probe reports a timeout, and one minute later at
    /// load 28 the identical command returns exit 0. Ten seconds stays well
    /// inside the 35s Lume budget and the 40s attempt timeout.
    static let guestCommandTimeoutSeconds: UInt32 = 10
    static let lumeTimeoutSeconds: UInt32 = 35
    static let maximumOutputBytes = 4 * 1_024

    // Run a fixed no-op through the bootstrap guest-command wrapper. This
    // proves credentialed reachability and executor readiness, not server
    // identity: production tenant commands remain disabled until a signed
    // guest-control agent pins a per-VM identity.
    /// Takes the credential because both paths in the wrapped command have to
    /// name an account that exists in *this* guest: the launchd job's
    /// `WorkingDirectory` and its `HOME`. Not taking it here is why they were
    /// left pointing at the shared account that per-sandbox identities removed.
    static func command(
        idempotencyKey: UUID,
        credential: LumeGuestCredential
    ) throws -> String {
        try LumeGuestCommandEncoder.encode(
            SandboxGuestCommandRequest(
                idempotencyKey: idempotencyKey,
                executable: "/usr/bin/true",
                workingDirectory: credential.bootstrapHome,
                timeoutSeconds: guestCommandTimeoutSeconds
            ),
            home: credential.bootstrapHome
        )
    }

    /// Why the guest is not ready yet, in words a timeout can repeat.
    ///
    /// The probe used to return `Bool`, so a readiness timeout could say only
    /// that it had happened. Working out whether that meant no SSH, a broken
    /// wrapper, or a guest that was merely busy took a live VM and a hand-run
    /// command; the reason belongs in the error.
    package enum Readiness: Sendable, Equatable {
        case ready
        case notReady(String)
    }

    static func run(
        runner: SandboxProcessRunner,
        executable: URL,
        storagePath: String,
        environment: [String: String],
        name: String,
        credential: LumeGuestCredential,
        policy: LumeGuestReadinessPolicy,
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async throws -> Readiness {
        let deterministicEnvironment = environment.merging(
            [
                "LANG": "C",
                "LC_ALL": "C",
                // In the environment, never argv: `ps` exposes arguments.
                LumeGuestCredential.passwordEnvironmentVariable:
                    credential.bootstrapPassword,
            ]
        ) { _, deterministic in deterministic }
        let encodedCommand = try command(
            idempotencyKey: UUID(),
            credential: credential
        )
        let result = try await LumeGuestReadinessDeadline.run(
            clock: clock,
            deadline: deadline
        ) {
            try await runner.run(
                executable: executable,
                arguments: [
                    "ssh",
                    name,
                    "--storage", storagePath,
                    "--timeout", String(lumeTimeoutSeconds),
                    "--nio-only",
                    "--user", credential.bootstrapUsername,
                    encodedCommand,
                ],
                environment: deterministicEnvironment,
                timeoutSeconds: policy.attemptTimeoutSeconds,
                maximumOutputBytes: maximumOutputBytes
            )
        }
        guard result.exitCode == 0 else {
            return .notReady("lume ssh exited \(result.exitCode)")
        }
        guard !result.standardOutputTruncated,
              !result.standardErrorTruncated
        else {
            return .notReady("lume ssh output was truncated")
        }
        guard let guestResult = try? LumeGuestCommandResultDecoder.decode(
            result.standardOutput
        ) else {
            return .notReady("the guest returned no decodable result envelope")
        }
        guard !guestResult.timedOut else {
            return .notReady(
                "the guest command hit its \(guestCommandTimeoutSeconds)s "
                    + "deadline, which a heavily loaded first boot can do"
            )
        }
        guard guestResult.exitCode == 0 else {
            return .notReady(
                "the guest command exited \(guestResult.exitCode)"
            )
        }
        guard !guestResult.standardOutputTruncated,
              !guestResult.standardErrorTruncated
        else {
            return .notReady("the guest command output was truncated")
        }
        return .ready
    }
}

enum LumeGuestReadinessDeadline {
    static func run<T: Sendable>(
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard clock.now < deadline else {
            throw LumeGuestReadinessDeadlineExceeded()
        }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await clock.sleep(until: deadline, tolerance: .zero)
                throw LumeGuestReadinessDeadlineExceeded()
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else {
                throw LumeGuestReadinessDeadlineExceeded()
            }
            return value
        }
    }
}

struct LumeGuestReadinessDeadlineExceeded: Error {}
