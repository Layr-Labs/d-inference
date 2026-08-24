import Foundation
import Testing
@testable import ProviderCore

@Suite("ProcessLifecycle PID lock")
struct ProcessLifecycleTests {

    private func tempPIDFile() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-darkbloom-pid-\(UUID().uuidString).pid")
    }

    @Test("acquire writes our exact kernel identity")
    func acquireWritesIdentity() throws {
        let pidFile = tempPIDFile()
        defer { ProcessLifecycle.releaseSingleInstanceLock(at: pidFile) }

        try ProcessLifecycle.acquireSingleInstanceLock(at: pidFile)
        #expect(ProcessLifecycle.singleInstanceOwner(at: pidFile) == ProcessIdentity.current())
    }

    @Test("release deletes the PID file")
    func releaseDeletesFile() throws {
        let pidFile = tempPIDFile()
        try ProcessLifecycle.acquireSingleInstanceLock(at: pidFile)
        #expect(FileManager.default.fileExists(atPath: pidFile.path))

        ProcessLifecycle.releaseSingleInstanceLock(at: pidFile)
        #expect(!FileManager.default.fileExists(atPath: pidFile.path))
    }

    @Test("legacy PID-only files are overwritten without signaling")
    func legacyPIDIsNotSignaled() throws {
        let pidFile = tempPIDFile()
        let current = ProcessIdentity(pid: 200, startTimeMicros: 2_000)
        var terminationCount = 0
        try "123\n".write(to: pidFile, atomically: true, encoding: .utf8)

        try ProcessLifecycle.acquireSingleInstanceLock(
            at: pidFile,
            terminationGracePeriod: 0,
            currentIdentity: current,
            readIdentity: { _ in ProcessIdentity(pid: 123, startTimeMicros: 1_000) },
            terminate: { _, _ in
                terminationCount += 1
                return true
            }
        )

        #expect(terminationCount == 0)
        #expect(ProcessLifecycle.singleInstanceOwner(at: pidFile) == current)
    }

    @Test("acquire is idempotent for the running process")
    func acquireIdempotent() throws {
        let pidFile = tempPIDFile()
        defer { ProcessLifecycle.releaseSingleInstanceLock(at: pidFile) }

        try ProcessLifecycle.acquireSingleInstanceLock(at: pidFile)
        try ProcessLifecycle.acquireSingleInstanceLock(at: pidFile)
        #expect(ProcessLifecycle.singleInstanceOwner(at: pidFile) == ProcessIdentity.current())
    }

    @Test("a reused PID can never authorize termination")
    func reusedPIDIsNotSignaled() throws {
        let pidFile = tempPIDFile()
        let old = ProcessIdentity(pid: 123, startTimeMicros: 1_000)
        let reused = ProcessIdentity(pid: 123, startTimeMicros: 2_000)
        let current = ProcessIdentity(pid: 200, startTimeMicros: 3_000)
        try writeOwner(old, to: pidFile)
        var terminationCount = 0

        try ProcessLifecycle.acquireSingleInstanceLock(
            at: pidFile,
            terminationGracePeriod: 0,
            currentIdentity: current,
            readIdentity: { $0 == reused.pid ? reused : nil },
            terminate: { _, _ in
                terminationCount += 1
                return true
            }
        )

        #expect(terminationCount == 0)
        #expect(ProcessLifecycle.singleInstanceOwner(at: pidFile) == current)
    }

    @Test("a matching live identity is terminated before takeover")
    func matchingIdentityIsTerminated() throws {
        let pidFile = tempPIDFile()
        let old = ProcessIdentity(pid: 123, startTimeMicros: 1_000)
        let current = ProcessIdentity(pid: 200, startTimeMicros: 3_000)
        try writeOwner(old, to: pidFile)
        var terminated: ProcessIdentity?

        try ProcessLifecycle.acquireSingleInstanceLock(
            at: pidFile,
            terminationGracePeriod: 0.25,
            currentIdentity: current,
            readIdentity: { $0 == old.pid ? old : nil },
            terminate: { identity, grace in
                terminated = identity
                #expect(grace == 0.25)
                return true
            }
        )

        #expect(terminated == old)
        #expect(ProcessLifecycle.singleInstanceOwner(at: pidFile) == current)
    }

    @Test("failed termination prevents a second provider from starting")
    func failedTerminationAbortsTakeover() throws {
        let pidFile = tempPIDFile()
        let old = ProcessIdentity(pid: 123, startTimeMicros: 1_000)
        let current = ProcessIdentity(pid: 200, startTimeMicros: 3_000)
        try writeOwner(old, to: pidFile)

        #expect(throws: ProcessLifecycleError.existingProviderDidNotExit(123)) {
            try ProcessLifecycle.acquireSingleInstanceLock(
                at: pidFile,
                terminationGracePeriod: 0,
                currentIdentity: current,
                readIdentity: { _ in old },
                terminate: { _, _ in false }
            )
        }
        #expect(ProcessLifecycle.singleInstanceOwner(at: pidFile) == old)
    }

    @Test("a stale owner cannot remove its successor's record")
    func staleReleasePreservesSuccessor() throws {
        let pidFile = tempPIDFile()
        let old = ProcessIdentity(pid: 123, startTimeMicros: 1_000)
        let successor = ProcessIdentity(pid: 200, startTimeMicros: 3_000)
        try writeOwner(successor, to: pidFile)

        ProcessLifecycle.releaseSingleInstanceLock(
            at: pidFile,
            currentIdentity: old
        )

        #expect(ProcessLifecycle.singleInstanceOwner(at: pidFile) == successor)
    }

    @Test("standalone and connected launches share one locked housekeeping pass")
    func mediaServingLockOrdersHousekeeping() throws {
        for launchMode in ["standalone", "coordinator-connected"] {
            let expectedPIDFile = tempPIDFile()
            var events: [String] = []
            var telemetryPurgeCount = 0
            var videoPurgeCount = 0

            let acquired = ProcessLifecycle.acquireMediaServingLock(
                acquireLock: {
                    events.append("lock")
                    return expectedPIDFile
                },
                purgeLegacyTelemetryQueue: {
                    events.append("telemetry")
                    telemetryPurgeCount += 1
                },
                purgeLegacyVideoFiles: {
                    events.append("video")
                    videoPurgeCount += 1
                })

            #expect(acquired == expectedPIDFile, "failed mode: \(launchMode)")
            #expect(
                events == ["lock", "telemetry", "video"],
                "failed mode: \(launchMode)")
            #expect(telemetryPurgeCount == 1, "failed mode: \(launchMode)")
            #expect(videoPurgeCount == 1, "failed mode: \(launchMode)")
        }
    }

    @Test("failed media-serving lock acquisition cannot purge legacy artifacts")
    func mediaServingLockFailureSkipsHousekeeping() {
        struct LockFailure: Error {}
        var telemetryPurgeCount = 0
        var videoPurgeCount = 0

        #expect(throws: LockFailure.self) {
            try ProcessLifecycle.acquireMediaServingLock(
                acquireLock: {
                    throw LockFailure()
                },
                purgeLegacyTelemetryQueue: {
                    telemetryPurgeCount += 1
                },
                purgeLegacyVideoFiles: {
                    videoPurgeCount += 1
                })
        }
        #expect(telemetryPurgeCount == 0)
        #expect(videoPurgeCount == 0)
    }

    private func writeOwner(
        _ identity: ProcessIdentity,
        to pidFile: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: pidFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        var data = try encoder.encode(
            ProcessLifecycle.SingleInstanceOwner(processIdentity: identity)
        )
        data.append(0x0A)
        try data.write(to: pidFile, options: .atomic)
    }
}
