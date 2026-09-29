import Foundation
import Testing

@testable import ProviderCore

@Suite("Whole-Mac reservation correlation")
struct WholeMacServiceReservationTests {
    @Test func snapshotSeparatesLocalWorkAndEchoesActualCharges() {
        let budget = WholeMacServiceBudget()
        let a = "00000000-0000-4000-8000-00000000000a"
        let b = "00000000-0000-4000-8000-00000000000b"
        #expect(budget.acquire(ownerID: "local", concurrency: 8))
        #expect(budget.acquire(ownerID: "b", concurrency: 16, serviceReservationID: b.uppercased()))
        #expect(budget.acquire(ownerID: "a", concurrency: 24, serviceReservationID: a))
        let snapshot = budget.snapshot()
        #expect(abs(snapshot.usedFraction - (1.0 / 8 + 1.0 / 16 + 1.0 / 24)) < 1e-12)
        let expected: [WholeMacServiceReservation] = [
            .init(id: a, usedFraction: 1.0 / 24), .init(id: b, usedFraction: 1.0 / 16)]
        #expect(snapshot.reservations == expected)
        // An attempt can own one lease, including across different models.
        #expect(!budget.acquire(ownerID: "duplicate", concurrency: 16, serviceReservationID: a.uppercased()))
        #expect(budget.snapshot() == snapshot)
        budget.release(ownerID: "unknown")
        #expect(budget.snapshot() == snapshot)
        budget.release(ownerID: "a")
        #expect(budget.snapshot().reservations == [.init(id: b, usedFraction: 1.0 / 16)])
        // Retirement frees both the resource and its correlation identity.
        #expect(budget.acquire(ownerID: "retry", concurrency: 8, serviceReservationID: a))
        #expect(budget.snapshot().reservations.first?.usedFraction == 1.0 / 8)
    }

    @Test func malformedCorrelationNeverMakesLocalAllowanceFree() {
        let budget = WholeMacServiceBudget()
        #expect(budget.acquire(ownerID: "bad", concurrency: 1, serviceReservationID: "client-sensitive-id"))
        #expect(budget.snapshot() == .init(usedFraction: 1, reservations: []))
        #expect(!budget.acquire(ownerID: "next", concurrency: 24))
    }

    @Test func totalAndReservationListShareOneAtomicSnapshot() async {
        let budget = WholeMacServiceBudget()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<16 {
                group.addTask {
                    let id = UUID().uuidString
                    for _ in 0..<100 {
                        #expect(budget.acquire(ownerID: "owner-\(index)", concurrency: 16, serviceReservationID: id))
                        let snapshot = budget.snapshot()
                        #expect(snapshot.usedFraction == snapshot.reservations.reduce(0) { $0 + $1.usedFraction })
                        #expect(Set(snapshot.reservations.map(\.id)).count == snapshot.reservations.count)
                        budget.release(ownerID: "owner-\(index)")
                    }
                }
            }
        }
        #expect(budget.snapshot() == .init(usedFraction: 0, reservations: []))
    }
}
