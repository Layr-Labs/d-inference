import Foundation
import Testing
@testable import ProviderCore

private let hostGiB: UInt64 = 1 << 30

/// Inject only host counters; use the real sampler policy and ledger transaction.
private final class SharedHostUsage: @unchecked Sendable {
    private let lock = NSLock()
    private var freeGiB: UInt64
    private let policy: SystemMemory.AvailabilityPolicy

    init(freeGiB: UInt64, policy: SystemMemory.AvailabilityPolicy) {
        self.freeGiB = freeGiB
        self.policy = policy
    }

    func setFree(_ value: UInt64) { lock.withLock { freeGiB = value } }

    func read() -> ProcessMemoryLedger.Usage {
        lock.withLock {
            .init(activeBytes: 16 * hostGiB, cacheBytes: 0,
                systemAvailableBytes: SystemMemory.availableBytes(
                    freePages: freeGiB * hostGiB / 16_384,
                    inactivePages: 211 * hostGiB / 16_384,
                    pageSize: 16_384, policy: policy) ?? .max)
        }
    }

    func ledger() -> ProcessMemoryLedger {
        ProcessMemoryLedger(policy: .init(epoch: 1,
            capBytes: UnifiedMemoryCap.hardCapBytes(physicalBytes: 512 * hostGiB),
            reserveBytes: UnifiedMemoryCap.defaultActivationReserveBytes), readUsage: read)
    }
}

@Test func freeOnlyAtomicLoadClaimRejectsForeignInactiveCredit() throws {
    let reserve = UnifiedMemoryCap.loadReserveBytes(
        physicalBytes: 512 * hostGiB, configReserveBytes: 40 * hostGiB)
    for policy in [SystemMemory.AvailabilityPolicy.reclaimable, .freeOnly] {
        let usage = SharedHostUsage(freeGiB: 11, policy: policy)
        let ledger = usage.ledger()
        let owner = ledger.createOwner()
        // Same claim as GlobalKVCacheBudget.claimPendingLoad: padded weights +
        // minimum KV, with activations in ledger policy and OS reserve separate.
        if policy == .freeOnly {
            #expect(throws: ProcessMemoryLedger.Refusal.insufficientCapacity) {
                try ledger.replaceCharge(owner: owner.owner, expectedRevision: owner.revision,
                    expectedPolicyEpoch: 1, chargedBytes: 25 * hostGiB,
                    additionalSystemReserveBytes: reserve)
            }
            #expect(ledger.snapshot().chargedBytes == 0)
            #expect(ledger.retire(owner.owner) == .retired)
            #expect(ledger.snapshot().ownerCount == 0)
        } else {
            let claimed = try ledger.replaceCharge(owner: owner.owner,
                expectedRevision: owner.revision, expectedPolicyEpoch: 1,
                chargedBytes: 25 * hostGiB, additionalSystemReserveBytes: reserve)
            #expect(claimed.chargedBytes == 25 * hostGiB)
        }
    }
}

@Test func freeOnlyLoadRecheckSeesForeignGrowthAndActualRelease() throws {
    let usage = SharedHostUsage(freeGiB: 100, policy: .freeOnly)
    let ledger = usage.ledger()
    let reserve = UnifiedMemoryCap.loadReserveBytes(
        physicalBytes: 512 * hostGiB, configReserveBytes: 40 * hostGiB)
    let owner = ledger.createOwner()
    let claim = try ledger.replaceCharge(owner: owner.owner, expectedRevision: owner.revision,
        expectedPolicyEpoch: 1, chargedBytes: 25 * hostGiB,
        additionalSystemReserveBytes: reserve)
    usage.setFree(11) // Another process grows while load setup suspends.
    #expect(throws: ProcessMemoryLedger.Refusal.insufficientCapacity) {
        try ledger.recheckCharge(owner: claim.owner, expectedRevision: claim.revision,
            expectedPolicyEpoch: 1, additionalSystemReserveBytes: reserve)
    }
    #expect(ledger.snapshot().chargedBytes == 25 * hostGiB)
    usage.setFree(100) // Real freed pages, not a speculative inactive-page estimate.
    try ledger.recheckCharge(owner: claim.owner, expectedRevision: claim.revision,
        expectedPolicyEpoch: 1, additionalSystemReserveBytes: reserve)
    let competitor = ledger.createOwner()
    #expect(throws: ProcessMemoryLedger.Refusal.insufficientCapacity) {
        try ledger.replaceCharge(owner: competitor.owner, expectedRevision: competitor.revision,
            expectedPolicyEpoch: 1, chargedBytes: 25 * hostGiB,
            additionalSystemReserveBytes: reserve)
    }
    _ = try ledger.replaceCharge(owner: claim.owner, expectedRevision: claim.revision,
        expectedPolicyEpoch: 1, chargedBytes: 0)
    #expect(ledger.retire(claim.owner) == .retired)
    _ = try ledger.replaceCharge(owner: competitor.owner, expectedRevision: competitor.revision,
        expectedPolicyEpoch: 1, chargedBytes: 25 * hostGiB,
        additionalSystemReserveBytes: reserve)
}

@Test func freeOnlyRuntimeClaimCannotSpendInactiveHeadroom() throws {
    let usage = SharedHostUsage(freeGiB: 11, policy: .freeOnly)
    let ledger = usage.ledger()
    let owner = ledger.createOwner()
    #expect(throws: ProcessMemoryLedger.Refusal.insufficientCapacity) {
        try ledger.replaceCharge(owner: owner.owner, expectedRevision: owner.revision,
            expectedPolicyEpoch: 1, chargedBytes: 6 * hostGiB)
    }
    #expect(ledger.snapshot().remainingBytes == 11 * hostGiB
        - UnifiedMemoryCap.defaultActivationReserveBytes)
}
