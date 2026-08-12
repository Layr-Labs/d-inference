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

    @Test("media-serving launch paths acquire the lock before one housekeeping pass")
    func mediaServingLockOrdersHousekeeping() throws {
        let expectedPIDFile = tempPIDFile()
        var events: [String] = []
        var cleanupCount = 0

        let acquired = try ProcessLifecycle.acquireMediaServingLock(
            acquireLock: {
                events.append("lock")
                return expectedPIDFile
            },
            purgeLegacyVideoFiles: {
                events.append("housekeeping")
                cleanupCount += 1
            })

        #expect(acquired == expectedPIDFile)
        #expect(events == ["lock", "housekeeping"])
        #expect(cleanupCount == 1)
    }

    @Test("failed media-serving lock acquisition cannot purge legacy files")
    func mediaServingLockFailureSkipsHousekeeping() {
        struct LockFailure: Error {}
        var cleanupCount = 0

        #expect(throws: LockFailure.self) {
            try ProcessLifecycle.acquireMediaServingLock(
                acquireLock: {
                    throw LockFailure()
                },
                purgeLegacyVideoFiles: {
                    cleanupCount += 1
                })
        }
        #expect(cleanupCount == 0)
    }
}
