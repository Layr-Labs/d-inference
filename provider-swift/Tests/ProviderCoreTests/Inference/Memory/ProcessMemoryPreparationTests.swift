import Foundation
import Testing
@testable import ProviderCore

private final class ProcessMemoryPreparationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private weak var ledger: ProcessMemoryLedger?
    private var events: [String] = []

    func attach(_ ledger: ProcessMemoryLedger) { lock.withLock { self.ledger = ledger } }
    func recordedEvents() -> [String] { lock.withLock { events } }
    func clearEvents() { lock.withLock { events.removeAll() } }

    func prepare() {
        let ledger = lock.withLock { self.ledger }
        // This reenters the ledger lock. A preparation accidentally moved into
        // the transaction would deadlock instead of initializing safely outside.
        #expect(ledger?.policySnapshot().epoch != nil)
        lock.withLock { events.append("prepare") }
    }

    func read() -> ProcessMemoryLedger.Usage {
        lock.withLock {
            #expect(events.last == "prepare")
            events.append("read")
        }
        return .init(activeBytes: 0, cacheBytes: 0, systemAvailableBytes: .max)
    }
}

@Test func processLedgerPreparationIsLazyAndOutsideEveryUsageTransaction() throws {
    let probe = ProcessMemoryPreparationProbe()
    let ledger = ProcessMemoryLedger(
        policy: .init(epoch: 1, capBytes: 100, reserveBytes: 0),
        prepareUsage: probe.prepare, readUsage: probe.read)
    probe.attach(ledger)
    let empty = ledger.createOwner()
    #expect(ledger.state(for: empty.owner) == empty)
    #expect(probe.recordedEvents().isEmpty)

    let owner = try ledger.replaceCharge(
        owner: empty.owner, expectedRevision: empty.revision,
        expectedPolicyEpoch: 1, chargedBytes: 100)
    #expect(probe.recordedEvents() == ["prepare", "read"])
    probe.clearEvents()

    try ledger.recheckCharge(
        owner: owner.owner, expectedRevision: owner.revision, expectedPolicyEpoch: 1)
    #expect(probe.recordedEvents() == ["prepare", "read"])
    probe.clearEvents()

    #expect(ledger.snapshot().remainingBytes == 0)
    #expect(probe.recordedEvents() == ["prepare", "read"])
    probe.clearEvents()

    // Policy changes and retirement are scalar-only. A subsequent reduction
    // still warms outside the lock, but neither reads usage nor reapplies gates.
    #expect(ledger.updatePolicy(.init(epoch: 2, capBytes: 0, reserveBytes: 100)))
    _ = ledger.retire(owner.owner)
    let closing = try #require(ledger.state(for: owner.owner))
    #expect(probe.recordedEvents().isEmpty)
    _ = try ledger.replaceCharge(
        owner: closing.owner, expectedRevision: closing.revision,
        expectedPolicyEpoch: 0, chargedBytes: 0, additionalSystemReserveBytes: .max)
    #expect(probe.recordedEvents() == ["prepare"])
    #expect(ledger.state(for: owner.owner) == nil)
    probe.clearEvents()

    // The factory creates this adapter before passing it into native Admission.
    // Even a fresh engine with no charge prepares the reader at that boundary.
    let native = EngineProcessMemoryOwner(ledger: ledger)
    #expect(probe.recordedEvents() == ["prepare"])
    #expect(native.snapshot()?.chargedBytes == 0)
    native.retire()
}
