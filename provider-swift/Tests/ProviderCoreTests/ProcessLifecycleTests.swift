import Foundation
import Testing
@testable import ProviderCore

@Suite("ProcessLifecycle PID lock")
struct ProcessLifecycleTests {

    private func tempPIDFile() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-darkbloom-pid-\(UUID().uuidString).pid")
    }

    @Test("acquire writes our PID")
    func acquireWritesPID() throws {
        let pidFile = tempPIDFile()
        defer { ProcessLifecycle.releaseSingleInstanceLock(at: pidFile) }

        try ProcessLifecycle.acquireSingleInstanceLock(at: pidFile)
        let written = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(written == "\(ProcessInfo.processInfo.processIdentifier)")
    }

    @Test("release deletes the PID file")
    func releaseDeletesFile() throws {
        let pidFile = tempPIDFile()
        try ProcessLifecycle.acquireSingleInstanceLock(at: pidFile)
        #expect(FileManager.default.fileExists(atPath: pidFile.path))

        ProcessLifecycle.releaseSingleInstanceLock(at: pidFile)
        #expect(!FileManager.default.fileExists(atPath: pidFile.path))
    }

    @Test("acquire over a stale PID file overwrites it")
    func acquireOverStalePIDOverwrites() throws {
        let pidFile = tempPIDFile()
        defer { ProcessLifecycle.releaseSingleInstanceLock(at: pidFile) }

        // Write a clearly-stale PID: 1 (init) is alive, but won't be us.
        try "999999\n".write(to: pidFile, atomically: true, encoding: .utf8)
        // 999999 won't be alive -- kill(999999, 0) returns ESRCH -- so the
        // acquire path skips the kill and just overwrites.
        try ProcessLifecycle.acquireSingleInstanceLock(at: pidFile)

        let written = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(written == "\(ProcessInfo.processInfo.processIdentifier)")
    }

    @Test("acquire is idempotent for the running process")
    func acquireIdempotent() throws {
        let pidFile = tempPIDFile()
        defer { ProcessLifecycle.releaseSingleInstanceLock(at: pidFile) }

        try ProcessLifecycle.acquireSingleInstanceLock(at: pidFile)
        try ProcessLifecycle.acquireSingleInstanceLock(at: pidFile)
        // Should not throw, file should still contain our PID.
        let written = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(written == "\(ProcessInfo.processInfo.processIdentifier)")
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
}
