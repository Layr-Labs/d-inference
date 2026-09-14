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
    static let guestCommandTimeoutSeconds: UInt32 = 1
    static let lumeTimeoutSeconds: UInt32 = 35
    static let maximumOutputBytes = 4 * 1_024

    // Run a fixed no-op through the bootstrap guest-command wrapper. This
    // proves credentialed reachability and executor readiness, not server
    // identity: production tenant commands remain disabled until a signed
    // guest-control agent pins a per-VM identity.
    static func command(idempotencyKey: UUID) throws -> String {
        try LumeGuestCommandEncoder.encode(
            SandboxGuestCommandRequest(
                idempotencyKey: idempotencyKey,
                executable: "/usr/bin/true",
                timeoutSeconds: guestCommandTimeoutSeconds
            )
        )
    }

    static func run(
        runner: SandboxProcessRunner,
        executable: URL,
        storagePath: String,
        environment: [String: String],
        name: String,
        policy: LumeGuestReadinessPolicy,
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async throws -> Bool {
        let deterministicEnvironment = environment.merging(
            ["LANG": "C", "LC_ALL": "C"]
        ) { _, deterministic in deterministic }
        let encodedCommand = try command(idempotencyKey: UUID())
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
                    encodedCommand,
                ],
                environment: deterministicEnvironment,
                timeoutSeconds: policy.attemptTimeoutSeconds,
                maximumOutputBytes: maximumOutputBytes
            )
        }
        let guestResult = try? LumeGuestCommandResultDecoder.decode(
            result.standardOutput
        )
        return result.exitCode == 0
            && !result.standardOutputTruncated
            && !result.standardErrorTruncated
            && guestResult?.exitCode == 0
            && guestResult?.timedOut == false
            && guestResult?.standardOutputTruncated == false
            && guestResult?.standardErrorTruncated == false
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
