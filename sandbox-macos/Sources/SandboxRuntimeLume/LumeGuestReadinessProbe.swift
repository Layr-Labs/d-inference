import Foundation
import SandboxRuntime

package struct LumeGuestReadinessPolicy: Sendable {
    // Pinned Lume uses a 30-second NIO connect timeout. Five seconds of
    // controller/CLI headroom keeps each probe finite while the outer
    // readiness deadline still permits a retry.
    package static let production = LumeGuestReadinessPolicy(
        attemptTimeoutSeconds: 35,
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

enum LumeGuestReadinessProbe {
    static let commandTimeoutSeconds: UInt32 = 1
    static let maximumOutputBytes = 4 * 1_024
    // Clear the SSH session environment before running a fixed, side-effect
    // free executable. This command is never derived from a tenant request.
    static let command = """
    /usr/bin/env -i HOME=/Users/lume LANG=C LC_ALL=C \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR=/tmp /usr/bin/true
    """

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
                    "--timeout", String(commandTimeoutSeconds),
                    "--nio-only",
                    command,
                ],
                environment: deterministicEnvironment,
                timeoutSeconds: policy.attemptTimeoutSeconds,
                maximumOutputBytes: maximumOutputBytes
            )
        }
        return result.exitCode == 0
            && !result.standardOutputTruncated
            && !result.standardErrorTruncated
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
