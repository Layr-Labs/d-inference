import Foundation
import Testing
@testable import ProviderCore

@Suite("Checkpoint per-file asynchronous coordination", .serialized)
struct SSDCheckpointFileCoordinatorTests {
    private let file = URL(fileURLWithPath: "/checkpoint-tests/first.dbk3")
    private let otherFile = URL(fileURLWithPath: "/checkpoint-tests/second.dbk3")

    @Test("same-file waiters are FIFO and unrelated files proceed independently")
    func fifoAndIndependentFiles() async throws {
        let coordinator = SSDCheckpointFileCoordinator()
        let owner = coordinator.makeAccess(to: file)
        try await owner.acquire()
        defer { owner.release() }
        let first = coordinator.makeAccess(to: file)
        let firstTask = Task { try await first.acquire() }
        defer { firstTask.cancel(); first.cancel(); first.release() }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { coordinator.pendingCount(for: file) == 1 }
        let second = coordinator.makeAccess(to: file)
        let secondTask = Task { try await second.acquire() }
        defer { secondTask.cancel(); second.cancel(); second.release() }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { coordinator.pendingCount(for: file) == 2 }
        let independent = coordinator.makeAccess(to: otherFile)
        try await independent.acquire()
        #expect(coordinator.trackedFileCount == 2)
        independent.release()
        owner.release()
        try await firstTask.value
        #expect(coordinator.pendingCount(for: file) == 1)
        first.release()
        try await secondTask.value
        second.release()
        #expect(coordinator.trackedFileCount == 0)
    }

    @Test("queued cancellation refunds a waiter without unlocking its active reader")
    func cancelledWaiter() async throws {
        let coordinator = SSDCheckpointFileCoordinator()
        let owner = coordinator.makeAccess(to: file)
        try await owner.acquire()
        defer { owner.release() }
        let queued = coordinator.makeAccess(to: file)
        let task = Task { try await queued.acquire() }
        defer { task.cancel(); queued.cancel(); queued.release() }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { coordinator.pendingCount(for: file) == 1 }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(coordinator.pendingCount(for: file) == 0)
        #expect(coordinator.trackedFileCount == 1)
        owner.cancel()
        #expect(coordinator.trackedFileCount == 1)
        owner.release()
        owner.release()
        #expect(coordinator.trackedFileCount == 0)
    }

    @Test("explicit cancellation before or during enqueue leaves no tombstones")
    func explicitCancellation() async throws {
        let coordinator = SSDCheckpointFileCoordinator()
        let before = coordinator.makeAccess(to: file)
        before.cancel()
        await #expect(throws: CancellationError.self) { try await before.acquire() }
        let owner = coordinator.makeAccess(to: file)
        try await owner.acquire()
        defer { owner.release() }
        let queued = coordinator.makeAccess(to: file)
        let task = Task { try await queued.acquire() }
        defer { task.cancel(); queued.cancel(); queued.release() }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { coordinator.pendingCount(for: file) == 1 }
        queued.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        owner.release()
        #expect(coordinator.trackedFileCount == 0)
    }

    @Test("handoff racing cancellation resumes exactly once and prunes every file")
    func cancellationHandoff() async throws {
        let coordinator = SSDCheckpointFileCoordinator()
        for offset in 0..<128 {
            let url = file.appendingPathComponent(String(offset))
            let owner = coordinator.makeAccess(to: url)
            try await owner.acquire()
            let queued = coordinator.makeAccess(to: url)
            let task = Task {
                defer { queued.release() }
                try await queued.acquire()
            }
            defer { owner.release(); task.cancel(); queued.cancel(); queued.release() }
            try await SSDCheckpointCoordinationTestSupport.waitUntil { coordinator.pendingCount(for: url) == 1 }
            let cancellation = Task.detached { task.cancel() }
            owner.release()
            await cancellation.value
            do { try await task.value } catch is CancellationError { }
            #expect(coordinator.trackedFileCount == 0)
        }
    }
}
