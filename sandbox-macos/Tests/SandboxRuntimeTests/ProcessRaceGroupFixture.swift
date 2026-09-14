import Darwin
import Foundation
@testable import SandboxRuntime

final class ProcessGroupSignalRecorder: @unchecked Sendable {
    struct Entry: Equatable {
        let group: pid_t
        let signal: Int32
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    var snapshot: [Entry] {
        lock.withLock { entries }
    }

    func record(group: pid_t, signal: Int32) {
        lock.withLock {
            entries.append(Entry(group: group, signal: signal))
        }
    }
}

struct ProcessGroupFixture {
    private let directory: URL
    private let descendantPID: URL
    private let leaderExit: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "darkbloom-process-race-\(UUID().uuidString)",
                isDirectory: true
            )
        descendantPID = directory.appendingPathComponent("descendant.pid")
        leaderExit = directory.appendingPathComponent("leader-exit")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func startExecution(
        hooks: ProcessExecutionTestHooks
    ) throws -> ProcessExecution {
        let execution = try ProcessExecution(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                """
                /bin/sh -c 'trap "" HUP TERM; while :; do /bin/sleep 1; done' &
                descendant=$!
                printf '%s' "$descendant" > "$1"
                while [ ! -e "$2" ]; do /bin/sleep 0.01; done
                exit 0
                """,
                "darkbloom-process-race",
                descendantPID.path,
                leaderExit.path,
            ],
            environment: [
                "HOME": directory.path,
                "LANG": "en_US.UTF-8",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "TMPDIR": directory.path,
            ],
            currentDirectory: nil,
            maximumOutputBytes:
                SandboxProcessRunner.defaultMaximumOutputBytes,
            testHooks: hooks
        )
        do {
            try execution.start()
        } catch {
            execution.cleanup()
            throw error
        }
        return execution
    }

    func allowLeaderToExit() throws {
        try Data().write(to: leaderExit, options: .withoutOverwriting)
    }

    func waitForDescendantIdentity() async throws -> ProcessBirthIdentity {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        repeat {
            if let value = try? String(
                contentsOf: descendantPID,
                encoding: .utf8
            ), let pid = pid_t(value),
               let identity = ProcessBirthIdentity.read(pid)
            {
                return identity
            }
            guard clock.now < deadline else {
                throw ProcessRaceFixtureError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        } while true
    }

    func waitUntilIdentityIsGone(
        _ identity: ProcessBirthIdentity
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while ProcessBirthIdentity.read(identity.pid) == identity {
            guard clock.now < deadline else {
                throw ProcessRaceFixtureError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func remove() {
        try? Data().write(to: leaderExit, options: .withoutOverwriting)
        try? FileManager.default.removeItem(at: directory)
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
