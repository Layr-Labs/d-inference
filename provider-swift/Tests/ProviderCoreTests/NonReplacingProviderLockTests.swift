import Foundation
import Testing
@testable import ProviderCore

@Suite("Non-replacing provider ownership")
struct NonReplacingProviderLockTests {
    @Test("A live legacy PID-only record is refused; the same stale record can be reclaimed")
    func legacyPIDOnlyRecord() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("darkbloom-legacy-no-replace-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("provider.pid")
        try "123\n".write(to: path, atomically: true, encoding: .utf8)
        let owner = ProcessIdentity(pid: 123, startTimeMicros: 1000)
        let contender = ProcessIdentity(pid: 456, startTimeMicros: 2000)
        var signals = 0
        #expect(throws: ProcessLifecycleError.singleInstanceLockBusy) {
            try ProcessLifecycle.acquireSingleInstanceLock(
                at: path, terminationGracePeriod: 0, currentIdentity: contender,
                readIdentity: { _ in owner }, terminate: { _, _ in signals += 1; return true },
                replaceExisting: false
            )
        }
        #expect(try String(contentsOf: path, encoding: .utf8) == "123\n")
        try ProcessLifecycle.acquireSingleInstanceLock(
            at: path, terminationGracePeriod: 0, currentIdentity: contender,
            readIdentity: { _ in nil }, terminate: { _, _ in signals += 1; return true },
            replaceExisting: false
        )
        #expect(signals == 0)
        #expect(ProcessLifecycle.singleInstanceOwner(at: path) == contender)
        ProcessLifecycle.releaseSingleInstanceLock(at: path, currentIdentity: contender)
    }

    @Test("Occupied kernel and legacy identity locks refuse without signaling", arguments: [false, true])
    func occupiedOwnerIsPreserved(holdsKernelLock: Bool) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("darkbloom-no-replace-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("provider.pid")
        let owner = ProcessIdentity(pid: 123, startTimeMicros: 1000)
        let contender = ProcessIdentity(pid: 456, startTimeMicros: 2000)
        let record = try JSONEncoder().encode(ProcessLifecycle.SingleInstanceOwner(processIdentity: owner))
        try record.write(to: path)
        let lock: SingleInstanceKernelLock?
        if holdsKernelLock {
            let acquired = try SingleInstanceKernelLock.tryAcquire(at: SingleInstanceKernelLock.sidecarPath(for: path))
            lock = try #require(acquired)
        } else {
            lock = nil
        }
        defer { lock?.release() }
        var signals = 0

        #expect(throws: ProcessLifecycleError.singleInstanceLockBusy) {
            try ProcessLifecycle.acquireSingleInstanceLock(
                at: path, terminationGracePeriod: 0, currentIdentity: contender,
                readIdentity: { $0 == owner.pid ? owner : nil },
                terminate: { _, _ in signals += 1; return true },
                replaceExisting: false
            )
        }
        #expect(signals == 0)
        #expect(try Data(contentsOf: path) == record)
        lock?.release()
        // The failed attempt must release any sidecar it acquired for a legacy
        // record, so a subsequent start can proceed once that owner has exited.
        try ProcessLifecycle.acquireSingleInstanceLock(
            at: path, terminationGracePeriod: 0, currentIdentity: contender,
            readIdentity: { _ in nil }, terminate: { _, _ in signals += 1; return true },
            replaceExisting: false
        )
        #expect(ProcessLifecycle.singleInstanceOwner(at: path) == contender)
        #expect(signals == 0)
        ProcessLifecycle.releaseSingleInstanceLock(at: path, currentIdentity: contender)
    }
}
