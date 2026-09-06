import Foundation
import Testing
@testable import ProviderCore

private final class LoadConstraintUsage: @unchecked Sendable {
    private let lock = NSLock()
    private var available: UInt64 = 70
    func setAvailable(_ bytes: UInt64) { lock.withLock { available = bytes } }
    func read() -> ProcessMemoryLedger.Usage {
        lock.withLock { .init(activeBytes: 40, cacheBytes: 0, systemAvailableBytes: available) }
    }
}

@Test func processLedgerLoadConstraintRechecksSameChargeWithFreshUsage() throws {
    let usage = LoadConstraintUsage()
    let ledger = ProcessMemoryLedger(
        policy: .init(epoch: 1, capBytes: 100, reserveBytes: 10), readUsage: usage.read)
    let empty = ledger.createOwner()
    let owner = try ledger.replaceCharge(
        owner: empty.owner, expectedRevision: empty.revision, expectedPolicyEpoch: 1,
        chargedBytes: 30, additionalSystemReserveBytes: 30)
    try ledger.recheckCharge(
        owner: owner.owner, expectedRevision: owner.revision, expectedPolicyEpoch: 1,
        additionalSystemReserveBytes: 30)
    usage.setAvailable(69)
    #expect(throws: ProcessMemoryLedger.Refusal.insufficientCapacity) {
        try ledger.recheckCharge(
            owner: owner.owner, expectedRevision: owner.revision, expectedPolicyEpoch: 1,
            additionalSystemReserveBytes: 30)
    }
    #expect(ledger.snapshot().chargedBytes == 30)
    // The additional load reserve does not silently change runtime KV policy.
    #expect(ledger.snapshot().remainingBytes == 20)
    #expect(ledger.updatePolicy(.init(epoch: 2, capBytes: 100, reserveBytes: 10)))
    #expect(throws: ProcessMemoryLedger.Refusal.stalePolicy) {
        try ledger.recheckCharge(
            owner: owner.owner, expectedRevision: owner.revision, expectedPolicyEpoch: 1)
    }
    _ = ledger.retire(owner.owner)
    let closing = try #require(ledger.state(for: owner.owner))
    #expect(throws: ProcessMemoryLedger.Refusal.ownerClosing) {
        try ledger.recheckCharge(
            owner: closing.owner, expectedRevision: closing.revision, expectedPolicyEpoch: 2)
    }
    _ = try ledger.replaceCharge(
        owner: closing.owner, expectedRevision: closing.revision, expectedPolicyEpoch: 0,
        chargedBytes: 0, additionalSystemReserveBytes: .max)
    #expect(ledger.snapshot().ownerCount == 0)
}
