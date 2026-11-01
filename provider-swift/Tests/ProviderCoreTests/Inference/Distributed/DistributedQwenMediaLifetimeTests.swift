import Foundation
import Testing
@testable import ProviderCore

@Suite("Qwen media host retirement")
struct DistributedQwenMediaLifetimeTests {
    private final class Record: @unchecked Sendable {
        let lock = NSLock()
        var events: [String] = []
        var key: DistributedQwenMediaLifetime.Submission?
        func add(_ event: String) { lock.withLock { events.append(event) } }
        var values: [String] { lock.withLock { events } }
        func save(_ key: DistributedQwenMediaLifetime.Submission) { lock.withLock { self.key = key } }
        var saved: DistributedQwenMediaLifetime.Submission? { lock.withLock { key } }
    }
    private actor Gate {
        var entered = false
        var waiter: CheckedContinuation<Void, Never>?
        func wait() async { entered = true; await withCheckedContinuation { waiter = $0 } }
        func open() { waiter?.resume(); waiter = nil }
        func waitForEntry() async { while !entered { await Task.yield() } }
    }

    private func owner(_ record: Record) -> DistributedQwenMediaLifetime {
        .init(wire: Data(repeating: 7, count: 64), release: { record.add("released") })
    }

    @Test func unsubmittedReleaseIsExplicitAndIdempotent() async throws {
        let record = Record()
        let owned = owner(record)
        owned.releaseIfUnsubmitted(); owned.releaseIfUnsubmitted()
        #expect(record.values == ["released"])
        await #expect(throws: DistributedQwenMediaLifetime.Failure.self) {
            try await owned.withSubmission(requestID: "same") { _, _ in 1 }
        }
    }

    @Test func rejectedSubmissionDropsWireBeforeAllowance() async throws {
        let record = Record()
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
        var wire: Data? = Data(bytesNoCopy: pointer, count: 64, deallocator: .custom { p, _ in
            p.deallocate(); record.add("dropped")
        })
        let resource = DistributedQwenMediaLifetime(wire: wire!, release: { record.add("released") })
        wire = nil
        enum Refusal: Error { case beforeAdmission }
        await #expect(throws: Refusal.self) {
            try await resource.withSubmission(requestID: "one") { bytes, _ in
                #expect(bytes.count == 64)
                throw Refusal.beforeAdmission
            }
        }
        #expect(record.values == ["dropped", "released"])
    }

    @Test func nativeRetirementBeforeSubmitEndsDoesNotRefund() async throws {
        let record = Record(), gate = Gate()
        let resource = owner(record)
        let task = Task {
            try await resource.withSubmission(requestID: "one") { bytes, key in
                #expect(bytes.count == 64)
                try resource.requireNativeRetirement(key)
                resource.nativeDidRetire(key)
                await gate.wait()
                return 17
            }
        }
        await gate.waitForEntry()
        #expect(record.values.isEmpty)
        resource.releaseIfUnsubmitted()
        #expect(record.values.isEmpty)
        await gate.open()
        #expect(try await task.value == 17)
        #expect(record.values == ["released"])
    }

    @Test func submitEndedWaitsForExactNativeGeneration() async throws {
        let record = Record()
        let owned = owner(record)
        _ = try await owned.withSubmission(requestID: "reused") { _, key in
            record.save(key); try owned.requireNativeRetirement(key); return true
        }
        #expect(record.values.isEmpty)
        let key = try #require(record.saved)
        owned.nativeDidRetire(.init(generation: UUID(), requestID: key.requestID))
        owned.nativeDidRetire(.init(generation: key.generation, requestID: "other"))
        #expect(record.values.isEmpty)
        owned.nativeDidRetire(key); owned.nativeDidRetire(key)
        #expect(record.values == ["released"])
    }

    @Test func cancelledSubmitStillWaitsForProducerAndNative() async throws {
        let record = Record(), gate = Gate()
        let resource = owner(record)
        let task = Task {
            try await resource.withSubmission(requestID: "one") { _, key in
                record.save(key); try resource.requireNativeRetirement(key)
                await gate.wait()
                try Task.checkCancellation()
            }
        }
        await gate.waitForEntry(); task.cancel()
        #expect(record.values.isEmpty)
        await gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(record.values.isEmpty)
        resource.nativeDidRetire(try #require(record.saved))
        #expect(record.values == ["released"])
    }

    @Test func secondSubmitCannotStealFirstOwnership() async throws {
        let record = Record(), gate = Gate()
        let resource = owner(record)
        let first = Task {
            try await resource.withSubmission(requestID: "same") { _, key in
                record.save(key); try resource.requireNativeRetirement(key)
                await gate.wait()
            }
        }
        await gate.waitForEntry()
        await #expect(throws: DistributedQwenMediaLifetime.Failure.self) {
            try await resource.withSubmission(requestID: "same") { _, _ in }
        }
        #expect(record.values.isEmpty)
        await gate.open(); try await first.value
        #expect(record.values.isEmpty)
        resource.nativeDidRetire(try #require(record.saved))
        #expect(record.values == ["released"])
    }

    @Test func unresolvedCleanupRemainsCharged() async throws {
        let record = Record()
        var resource: DistributedQwenMediaLifetime? = owner(record)
        if let resource {
            _ = try await resource.withSubmission(requestID: "one") { _, key in
                try resource.requireNativeRetirement(key); return 1
            }
            resource.releaseIfUnsubmitted()
        }
        resource = nil
        #expect(record.values.isEmpty)
    }
}
