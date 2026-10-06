import Foundation
import Testing

@testable import ProviderCore

final class ServiceReleaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func record(_ id: String) { lock.withLock { values.append(id) } }
    var ids: [String] { lock.withLock { values } }
}

@Suite("Service release requires pipeline completion and engine retirement")
struct ServiceReservationLifetimeTests {
    @Test(arguments: [true, false])
    func bothCompletionOrdersReleaseExactlyOnce(pipelineFirst: Bool) throws {
        let budget = WholeMacServiceBudget()
        let recorder = ServiceReleaseRecorder()
        let id = UUID().uuidString
        let lifetime = try #require(ServiceReservationLifetime(id: id) { released in
            // Reentering the budget proves release callbacks run outside both
            // locks, after the actual charge is removed.
            #expect(budget.snapshot().usedFraction == 0)
            recorder.record(released)
        })
        #expect(budget.acquire(ownerID: "engine-generated-id", concurrency: 16,
            serviceReservation: lifetime))
        if pipelineFirst {
            lifetime.finishPipeline()
            #expect(recorder.ids.isEmpty)
            budget.release(ownerID: "engine-generated-id")
        } else {
            // No heartbeat observes this fast acquire/retire pair. Completion
            // still produces explicit evidence when the pipeline ends.
            budget.release(ownerID: "engine-generated-id")
            #expect(recorder.ids.isEmpty)
            lifetime.finishPipeline()
        }
        #expect(recorder.ids == [id.lowercased()])
        lifetime.finishPipeline()
        budget.release(ownerID: "engine-generated-id")
        #expect(recorder.ids.count == 1)
        #expect(!budget.acquire(ownerID: "late", concurrency: 16, serviceReservation: lifetime))
        #expect(budget.count == 0)
    }

    @Test func rejectedAcquireDoesNotRetainALease() throws {
        let budget = WholeMacServiceBudget()
        let recorder = ServiceReleaseRecorder()
        let id = UUID().uuidString.lowercased()
        let lifetime = try #require(ServiceReservationLifetime(id: id, onReleased: recorder.record))
        #expect(budget.acquire(ownerID: "local-full", concurrency: 1))
        #expect(!budget.acquire(ownerID: "rejected", concurrency: 16, serviceReservation: lifetime))
        lifetime.finishPipeline()
        #expect(recorder.ids == [id])
        #expect(budget.usedFraction == 1)
        budget.release(ownerID: "local-full")
        #expect(recorder.ids.count == 1)
    }

    @Test func leaseRetirementsAndPipelineCompletionCanRace() async throws {
        let budget = WholeMacServiceBudget()
        let recorder = ServiceReleaseRecorder()
        let id = UUID().uuidString.lowercased()
        let lifetime = try #require(ServiceReservationLifetime(id: id, onReleased: recorder.record))
        #expect(budget.acquire(ownerID: "engine", concurrency: 16, serviceReservation: lifetime))
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask { lifetime.finishPipeline() }
                group.addTask { budget.release(ownerID: "engine") }
            }
        }
        #expect(recorder.ids == [id])
        #expect(budget.count == 0)
    }

    @Test func unacquiredAndMalformedIdentities() {
        let recorder = ServiceReleaseRecorder()
        for id in [nil, "", "client-request-id", String(repeating: "a", count: 36)] as [String?] {
            #expect(ServiceReservationLifetime(id: id, onReleased: recorder.record) == nil)
        }
        #expect(recorder.ids.isEmpty)
        let id = UUID().uuidString.lowercased()
        let lifetime = ServiceReservationLifetime(id: id, onReleased: recorder.record)
        lifetime?.finishPipeline()
        lifetime?.finishPipeline()
        #expect(recorder.ids == [id])
    }
}
