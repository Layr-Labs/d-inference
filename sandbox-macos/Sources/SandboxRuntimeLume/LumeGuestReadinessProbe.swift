import Foundation
import SandboxRuntime

package struct LumeGuestReadinessPolicy: Sendable {
    // Exercise the same launchd-backed wrapper used for tenant commands. The
    // probe gets the same 35-second Lume budget as a 30-second guest command,
    // plus five seconds for the host process to collect Lume's result.
    package static let production = LumeGuestReadinessPolicy(
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

enum LumeGuestReadinessProbe {
    static let guestCommandTimeoutSeconds: UInt32 = 1
    static let lumeTimeoutSeconds: UInt32 = 35
    static let maximumOutputBytes = 4 * 1_024

    // Run a fixed no-op through the production guest-command wrapper. A bare
    // SSH command only proves authentication; it does not prove that the
    // launchd domain, FIFO capture, watchdog, and teardown path are ready.
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
        let startedAt = Date()
        // #region agent log
        LumeRuntimeDebugLog.write(
            hypothesisId: "A,D",
            location: "LumeGuestReadinessProbe.swift:run-entry",
            message: "authenticated readiness probe started",
            data: [
                "vmRole": LumeRuntimeDebugLog.virtualMachineRole(name),
                "attemptTimeoutSeconds":
                    String(policy.attemptTimeoutSeconds),
            ]
        )
        // #endregion
        let deterministicEnvironment = environment.merging(
            ["LANG": "C", "LC_ALL": "C"]
        ) { _, deterministic in deterministic }
        do {
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
            let ready = result.exitCode == 0
                && !result.standardOutputTruncated
                && !result.standardErrorTruncated
                && guestResult?.exitCode == 0
                && guestResult?.timedOut == false
                && guestResult?.standardOutputTruncated == false
                && guestResult?.standardErrorTruncated == false
            // #region agent log
            LumeRuntimeDebugLog.write(
                hypothesisId: "A,D",
                location: "LumeGuestReadinessProbe.swift:run-result",
                message: "authenticated readiness probe completed",
                data: [
                    "vmRole": LumeRuntimeDebugLog.virtualMachineRole(name),
                    "elapsedMilliseconds": String(
                        Int(Date().timeIntervalSince(startedAt) * 1_000)
                    ),
                    "exitCode": String(result.exitCode),
                    "ready": String(ready),
                    "stdoutBytes": String(result.standardOutput.count),
                    "stderrBytes": String(result.standardError.count),
                ]
            )
            // #endregion
            return ready
        } catch {
            // #region agent log
            LumeRuntimeDebugLog.write(
                hypothesisId: "A,D",
                location: "LumeGuestReadinessProbe.swift:run-error",
                message: "authenticated readiness probe failed",
                data: LumeRuntimeDebugLog.errorData(error).merging([
                    "vmRole": LumeRuntimeDebugLog.virtualMachineRole(name),
                    "elapsedMilliseconds": String(
                        Int(Date().timeIntervalSince(startedAt) * 1_000)
                    ),
                ]) { _, observation in observation }
            )
            // #endregion
            throw error
        }
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
