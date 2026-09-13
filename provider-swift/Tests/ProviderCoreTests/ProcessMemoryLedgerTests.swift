import Dispatch
import Foundation
import Testing

@testable import ProviderCore

private typealias Ledger = ProcessMemoryLedger

private final class LedgerUsage: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Ledger.Usage(
        activeBytes: 0, cacheBytes: 0, systemAvailableBytes: .max)

    func set(active: UInt64 = 0, cache: UInt64 = 0, available: UInt64 = .max) {
        lock.withLock {
            value = Ledger.Usage(
                activeBytes: active, cacheBytes: cache, systemAvailableBytes: available)
        }
    }

    func read() -> Ledger.Usage { lock.withLock { value } }
}

private func makeLedger(
    cap: UInt64 = 1_000, reserve: UInt64 = 0, usage: LedgerUsage = LedgerUsage()
) -> Ledger {
    Ledger(policy: .init(epoch: 1, capBytes: cap, reserveBytes: reserve), readUsage: usage.read)
}

private func charge(
    _ ledger: Ledger, _ state: Ledger.OwnerState, _ bytes: UInt64, epoch: UInt64 = 1
) throws -> Ledger.OwnerState {
    try ledger.replaceCharge(
        owner: state.owner, expectedRevision: state.revision, expectedPolicyEpoch: epoch,
        chargedBytes: bytes)
}

private func reserve(_ ledger: Ledger, _ bytes: UInt64) throws -> Ledger.OwnerState {
    try charge(ledger, ledger.createOwner(), bytes)
}

private func materialize(
    _ ledger: Ledger, _ state: Ledger.OwnerState, _ bytes: UInt64
) throws -> Ledger.OwnerState {
    try ledger.recordMaterialization(
        owner: state.owner, expectedRevision: state.revision, materializedBytes: bytes)
}

@Test func processLedgerTwoOwnersFitWithoutMaterializationDoubleTax() throws {
    let usage = LedgerUsage()
    let ledger = makeLedger(usage: usage)
    usage.set(active: 300) // Unowned, already loaded weights.
    let a = try reserve(ledger, 300)
    usage.set(active: 500) // A owns exactly 200 of these bytes.
    _ = try materialize(ledger, a, 200)
    let b = try reserve(ledger, 400)
    #expect(ledger.snapshot().remainingBytes == 0)
    #expect(throws: Ledger.Refusal.insufficientCapacity) { try charge(ledger, b, 401) }
    usage.set(active: 900)
    _ = try materialize(ledger, b, 400)
    let snapshot = ledger.snapshot()
    #expect(snapshot.chargedBytes == 700)
    #expect(snapshot.materializedBytes == 600)
    #expect(snapshot.unmaterializedBytes == 100)
    #expect(snapshot.remainingBytes == 0)
    #expect(snapshot.commitmentDebtBytes == 0)
}

@Test func processLedgerIndependentEngineFloorsAndPromisesAdd() throws {
    let usage = LedgerUsage()
    let ledger = makeLedger(cap: 800, usage: usage)
    let idlePool = try reserve(ledger, 400)
    usage.set(active: 400)
    _ = try materialize(ledger, idlePool, 400)
    let otherEngine = try reserve(ledger, 400)
    #expect(ledger.snapshot().chargedBytes == 800)
    #expect(throws: Ledger.Refusal.insufficientCapacity) {
        try charge(ledger, otherEngine, 401)
    }
}

@Test func processLedgerSameBackingStageAdoptionReservesOnlyRemainingPromise() throws {
    let usage = LedgerUsage()
    let ledger = makeLedger(cap: 100, usage: usage)
    let engine = try reserve(ledger, 60)
    usage.set(active: 60)
    let staged = try materialize(ledger, engine, 60)
    // The same engine owns final private pages before SSD I/O. Adoption changes
    // native C from stage 60 to complete request promise 100, preserving M=60.
    let active = try charge(ledger, staged, 100)
    #expect(active.materializedBytes == 60)
    #expect(ledger.snapshot().unmaterializedBytes == 40)
    #expect(ledger.snapshot().remainingBytes == 0)
    #expect(throws: Ledger.Refusal.insufficientCapacity) { try charge(ledger, active, 101) }
}

@Test func processLedgerCopiedSourceAndTargetRemainAdditive() throws {
    let usage = LedgerUsage()
    let ledger = makeLedger(cap: 100, usage: usage)
    let source = try reserve(ledger, 60)
    usage.set(active: 60)
    _ = try materialize(ledger, source, 60)
    let target = ledger.createOwner()
    #expect(throws: Ledger.Refusal.insufficientCapacity) { try charge(ledger, target, 100) }
    #expect(ledger.updatePolicy(.init(epoch: 2, capBytes: 160, reserveBytes: 0)))
    let destination = try charge(ledger, target, 100, epoch: 2)
    usage.set(active: 160)
    _ = try materialize(ledger, destination, 100)
    #expect(ledger.snapshot().chargedBytes == 160)
    #expect(ledger.snapshot().remainingBytes == 0)
}

@Test func processLedgerFullyReservedMaterializationWorksAtCapAndUnderPolicyDebt() throws {
    let usage = LedgerUsage()
    let ledger = makeLedger(cap: 100, usage: usage)
    let owner = try reserve(ledger, 100)
    usage.set(active: 100)
    #expect(ledger.snapshot().commitmentDebtBytes == 100) // Allocation precedes proof.
    #expect(ledger.updatePolicy(.init(epoch: 2, capBytes: 80, reserveBytes: 0)))
    let live = try materialize(ledger, owner, 100)
    #expect(live.materializedBytes == 100)
    #expect(ledger.snapshot().unmaterializedBytes == 0)
    #expect(ledger.snapshot().remainingBytes == 0)
    #expect(throws: Ledger.Refusal.insufficientCapacity) {
        try charge(ledger, live, 101, epoch: 2)
    }
}

@Test func processLedgerWithdrawThenDestroyThenRefundHasNoAdmissionGap() throws {
    let usage = LedgerUsage()
    let ledger = makeLedger(cap: 100, usage: usage)
    let owner = try reserve(ledger, 100)
    usage.set(active: 100)
    _ = try materialize(ledger, owner, 100)
    let withdrawn = try ledger.withdrawCoverage(owner: owner.owner, bytes: 100)
    #expect(ledger.snapshot().commitmentDebtBytes == 100)
    let contender = ledger.createOwner()
    #expect(throws: Ledger.Refusal.insufficientCapacity) { try charge(ledger, contender, 1) }
    usage.set(active: 0) // Actual aliases have now drained.
    #expect(throws: Ledger.Refusal.insufficientCapacity) { try charge(ledger, contender, 1) }
    _ = try charge(ledger, withdrawn, 0)
    #expect(ledger.retire(owner.owner) == .retired)
    _ = try charge(ledger, contender, 100)
    #expect(ledger.snapshot().remainingBytes == 0)
}

@Test func processLedgerClosingPermitsReservedCompletionAndAllRetirementSteps() throws {
    let usage = LedgerUsage()
    let ledger = makeLedger(cap: 100, usage: usage)
    let owner = try reserve(ledger, 100)
    #expect(ledger.retire(owner.owner) == .draining(chargedBytes: 100, materializedBytes: 0))
    let closing = try #require(ledger.state(for: owner.owner))
    #expect(throws: Ledger.Refusal.ownerClosing) { try charge(ledger, closing, 101) }
    #expect(ledger.updatePolicy(.init(epoch: 2, capBytes: 0, reserveBytes: 0)))
    usage.set(active: 80) // A previously reserved allocation finishes after close.
    _ = try materialize(ledger, closing, 80)
    #expect(ledger.retire(owner.owner) == .draining(chargedBytes: 100, materializedBytes: 80))
    let withdrawn = try ledger.withdrawCoverage(owner: owner.owner, bytes: 80)
    usage.set(active: 0)
    _ = try charge(ledger, withdrawn, 0) // Old policy cannot block actual retirement.
    #expect(ledger.state(for: owner.owner) == nil)
    #expect(ledger.snapshot().ownerCount == 0)
    #expect(ledger.snapshot().closingOwnerCount == 0)
    #expect(ledger.snapshot().chargedBytes == 0)
    #expect(ledger.retire(owner.owner) == .alreadyRetired)
}

@Test func processLedgerClosingRetainsOtherChildrenUntilFinalDrain() throws {
    let usage = LedgerUsage()
    let ledger = makeLedger(cap: 120, usage: usage)
    let owner = try reserve(ledger, 120)
    usage.set(active: 120)
    _ = try materialize(ledger, owner, 120)
    _ = ledger.retire(owner.owner)
    let firstGone = try ledger.withdrawCoverage(owner: owner.owner, bytes: 60)
    usage.set(active: 60)
    let oneLeft = try charge(ledger, firstGone, 60)
    #expect(oneLeft.closing)
    #expect(ledger.snapshot().closingOwnerCount == 1)
    #expect(ledger.snapshot().materializedBytes == 60)
    let secondGone = try ledger.withdrawCoverage(owner: owner.owner, bytes: 60)
    usage.set(active: 0)
    _ = try charge(ledger, secondGone, 0)
    #expect(ledger.snapshot().ownerCount == 0)
}

@Test func processLedgerFailedNativePublicationCompensatesCurrentAggregate() throws {
    let usage = LedgerUsage()
    let ledger = makeLedger(cap: 160, usage: usage)
    let original = try reserve(ledger, 40)
    usage.set(active: 40)
    let live = try materialize(ledger, original, 40)
    let growth = try charge(ledger, live, 100)
    usage.set(active: 100)
    let allocated = try materialize(ledger, growth, 100)
    // Another native child adds 60 before the first candidate fails publication.
    _ = try charge(ledger, allocated, 160)
    let withdrawn = try ledger.withdrawCoverage(owner: live.owner, bytes: 60)
    usage.set(active: 40)
    // Recompute current aggregate: original 40 + surviving child's promise 60.
    // Restoring the obsolete pre-allocation baseline 40 would free live work.
    let restored = try charge(ledger, withdrawn, 100)
    #expect(restored.materializedBytes == 40)
    #expect(restored.chargedBytes == 100)
    #expect(ledger.snapshot().unmaterializedBytes == 60)
    #expect(throws: Ledger.Refusal.staleRevision) { try charge(ledger, live, 40) }
}

@Test func processLedgerPolicyShrinkRejectsGrowthButCannotStrandReductions() throws {
    let ledger = makeLedger(cap: 100)
    let owner = try reserve(ledger, 100)
    #expect(ledger.updatePolicy(.init(epoch: 2, capBytes: 10, reserveBytes: 0)))
    #expect(!ledger.updatePolicy(.init(epoch: 2, capBytes: 1_000, reserveBytes: 0)))
    #expect(!ledger.updatePolicy(.init(epoch: 0, capBytes: 1_000, reserveBytes: 0)))
    #expect(throws: Ledger.Refusal.stalePolicy) { try charge(ledger, owner, 101) }
    #expect(ledger.snapshot().commitmentDebtBytes == 90)
    let reduced = try charge(ledger, owner, 10)
    #expect(reduced.chargedBytes == 10)
    #expect(ledger.snapshot().commitmentDebtBytes == 0)
}

@Test func processLedgerRejectsInvalidCoverageAndImplicitWithdrawal() throws {
    let usage = LedgerUsage()
    let ledger = makeLedger(cap: 300, usage: usage)
    let owner = try reserve(ledger, 100)
    #expect(throws: Ledger.Refusal.invalidCoverage) { try materialize(ledger, owner, 101) }
    usage.set(active: 80)
    let live = try materialize(ledger, owner, 80)
    #expect(throws: Ledger.Refusal.invalidCoverage) {
        try ledger.withdrawCoverage(owner: owner.owner, bytes: 81)
    }
    #expect(throws: Ledger.Refusal.invalidCoverage) { try charge(ledger, live, 79) }
    #expect(throws: Ledger.Refusal.invalidCoverage) { try materialize(ledger, live, 79) }
    #expect(throws: Ledger.Refusal.staleRevision) { try materialize(ledger, owner, 80) }
    #expect(ledger.snapshot().materializedBytes == 80)
}

@Test func processLedgerRetiredGenerationCannotReleaseSuccessor() throws {
    let ledger = makeLedger(cap: 100)
    let old = try reserve(ledger, 100)
    _ = try charge(ledger, old, 0)
    #expect(ledger.retire(old.owner) == .retired)
    let successor = try reserve(ledger, 100)
    #expect(successor.owner != old.owner)
    #expect(ledger.retire(old.owner) == .alreadyRetired)
    #expect(throws: Ledger.Refusal.unknownOwner) { try charge(ledger, old, 0) }
    #expect(throws: Ledger.Refusal.unknownOwner) {
        try ledger.withdrawCoverage(owner: old.owner, bytes: 0)
    }
    #expect(ledger.state(for: successor.owner)?.chargedBytes == 100)
}

@Test func processLedgerRepeatedRejectionsNeverRefundLiveOwnership() throws {
    let ledger = makeLedger(cap: 100)
    let live = try reserve(ledger, 100)
    let waiting = ledger.createOwner()
    // This core has no clock, stale TTL, rejection streak or finalizer refund.
    for _ in 0..<1_000 {
        #expect(throws: Ledger.Refusal.insufficientCapacity) { try charge(ledger, waiting, 1) }
    }
    #expect(ledger.state(for: live.owner)?.chargedBytes == 100)
    _ = try charge(ledger, live, 0)
    _ = try charge(ledger, waiting, 100)
}

@Test func processLedgerHostOnlyChargeAndOSReserveStayAdditive() throws {
    let usage = LedgerUsage()
    usage.set(active: 100, cache: 50, available: 120)
    let ledger = makeLedger(cap: 1_000, reserve: 20, usage: usage)
    let host = try reserve(ledger, 100)
    let snapshot = ledger.snapshot()
    #expect(snapshot.materializedBytes == 0)
    #expect(snapshot.unmaterializedBytes == 100)
    #expect(snapshot.remainingBytes == 0)
    #expect(throws: Ledger.Refusal.insufficientCapacity) { try charge(ledger, host, 101) }
}

@Test func processLedgerOverflowRefusesWithoutPartialMutation() throws {
    let ledger = makeLedger(cap: .max)
    _ = try reserve(ledger, .max)
    let other = ledger.createOwner()
    #expect(throws: Ledger.Refusal.arithmeticOverflow) { try charge(ledger, other, 1) }
    #expect(ledger.state(for: other.owner)?.chargedBytes == 0)
    #expect(ledger.snapshot().chargedBytes == .max)
    let usage = LedgerUsage()
    usage.set(active: .max, cache: 1)
    let invalidUsage = makeLedger(cap: .max, usage: usage)
    let empty = invalidUsage.createOwner()
    #expect(throws: Ledger.Refusal.insufficientCapacity) { try charge(invalidUsage, empty, 1) }
    #expect(invalidUsage.snapshot().remainingBytes == 0)
}

/// Pure native-ownership model for transaction tests, not an actual engine or
/// allocator. All private physical plans appear in P before allocation; stage X
/// stays additive. Native Admission integration must establish this same order.
private final class NativeProjection: @unchecked Sendable {
    private let lock = NSLock()
    private let ledger: Ledger
    private var owner: Ledger.OwnerState
    private let nominal: UInt64
    private var physical: [String: UInt64] = [:]
    private var stage: UInt64 = 0

    init(_ ledger: Ledger, nominal: UInt64 = 100) throws {
        self.ledger = ledger
        self.nominal = nominal
        owner = try reserve(ledger, nominal)
    }

    func addPhysical(_ id: String, bytes: UInt64) throws {
        try lock.withLock {
            let total = physical.values.reduce(0, +) + bytes
            owner = try charge(ledger, owner, max(nominal, total) + stage)
            physical[id] = bytes // Metadata commits only after global acceptance.
        }
    }

    func addStage(bytes: UInt64) throws {
        try lock.withLock {
            let total = physical.values.reduce(0, +)
            owner = try charge(ledger, owner, max(nominal, total) + stage + bytes)
            stage += bytes
        }
    }

    func cancelUnallocatedPhysical(_ id: String) throws {
        try lock.withLock {
            var next = physical
            next.removeValue(forKey: id)
            owner = try charge(ledger, owner, max(nominal, next.values.reduce(0, +)) + stage)
            physical = next
        }
    }

    func recordMaterialized(_ bytes: UInt64) throws {
        try lock.withLock { owner = try materialize(ledger, owner, bytes) }
    }

    func physicalCount() -> Int { lock.withLock { physical.count } }
}

@Test func processLedgerNativeConcurrentPreparationsUseOneCompleteAggregate() async throws {
    let usage = LedgerUsage()
    let ledger = makeLedger(cap: 180, usage: usage)
    let native = try NativeProjection(ledger) // N100/P0/X0 => C100.
    let accepted = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
        for id in ["a", "b"] {
            group.addTask {
                do { try native.addPhysical(id, bytes: 60); return true }
                catch { return false }
            }
        }
        group.addTask {
            do { try native.addStage(bytes: 60); return true }
            catch { return false }
        }
        var count = 0
        for await result in group { if result { count += 1 } }
        return count
    }
    #expect(accepted == 3)
    #expect(ledger.snapshot().chargedBytes == 180) // max(P120, N100) + X60.
    #expect(throws: Ledger.Refusal.insufficientCapacity) {
        try native.addPhysical("refused", bytes: 1)
    }
    #expect(native.physicalCount() == 2)
    try native.cancelUnallocatedPhysical("a")
    #expect(ledger.snapshot().chargedBytes == 160) // max(P60, N100) + X60.
    usage.set(active: 60)
    try native.recordMaterialized(60)
    #expect(ledger.snapshot().unmaterializedBytes == 100)
    usage.set(active: 120)
    try native.recordMaterialized(120)
    #expect(ledger.snapshot().unmaterializedBytes == 40)
    #expect(ledger.snapshot().remainingBytes == 20)
}

@Test func processLedgerModelLoadAndNativeGrowthShareAtomicRemainder() async throws {
    let ledger = makeLedger(cap: 160)
    let native = try NativeProjection(ledger)
    let load = ledger.createOwner()
    let accepted = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
        group.addTask { (try? charge(ledger, load, 60)) != nil }
        group.addTask {
            do { try native.addPhysical("growth", bytes: 160); return true }
            catch { return false }
        }
        var count = 0
        for await result in group { if result { count += 1 } }
        return count
    }
    #expect(accepted == 1)
    #expect(ledger.snapshot().chargedBytes == 160)
    #expect(ledger.snapshot().remainingBytes == 0)
}

/// Deliberately blocks one scalar read to expose the unsafe old-U/new-M window.
/// Production readers must be bounded and must never use semaphores or I/O.
private final class PausedLedgerUsage: @unchecked Sendable {
    private let lock = NSLock()
    private var active: UInt64 = 0
    private var pauseNext = false
    let captured = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)

    func arm() { lock.withLock { pauseNext = true } }
    func setActive(_ bytes: UInt64) { lock.withLock { active = bytes } }

    func read() -> Ledger.Usage {
        let (bytes, pause) = lock.withLock {
            let result = (active, pauseNext)
            pauseNext = false
            return result
        }
        if pause {
            captured.signal()
            _ = resume.wait(timeout: .now() + 5)
        }
        return .init(activeBytes: bytes, cacheBytes: 0, systemAvailableBytes: .max)
    }
}

private final class LedgerThreadResults: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [String: Bool] = [:]
    func set(_ key: String, _ value: Bool) { lock.withLock { outcomes[key] = value } }
    func get(_ key: String) -> Bool? { lock.withLock { outcomes[key] } }
}

@Test func processLedgerCannotCombineOldUsageWithNewMaterializationCredit() throws {
    let usage = PausedLedgerUsage()
    let ledger = Ledger(
        policy: .init(epoch: 1, capBytes: 100, reserveBytes: 0), readUsage: usage.read)
    let a = try reserve(ledger, 60)
    let b = ledger.createOwner()
    let results = LedgerThreadResults()
    let tasks = DispatchGroup()
    let creditAttempted = DispatchSemaphore(value: 0)
    let creditFinished = DispatchSemaphore(value: 0)
    usage.arm()
    DispatchQueue.global().async(group: tasks) {
        do {
            _ = try charge(ledger, b, 100)
            results.set("bRefused", false)
        } catch {
            results.set("bRefused", error as? Ledger.Refusal == .insufficientCapacity)
        }
    }
    defer { usage.resume.signal() }
    try #require(usage.captured.wait(timeout: .now() + 2) == .success)
    usage.setActive(60) // A materializes after B captured the older U=0.
    DispatchQueue.global().async(group: tasks) {
        creditAttempted.signal()
        results.set("aCredited", (try? materialize(ledger, a, 60)) != nil)
        creditFinished.signal()
    }
    try #require(creditAttempted.wait(timeout: .now() + 2) == .success)
    #expect(creditFinished.wait(timeout: .now() + 0.05) == .timedOut)
    usage.resume.signal()
    try #require(tasks.wait(timeout: .now() + 2) == .success)
    #expect(results.get("bRefused") == true)
    #expect(results.get("aCredited") == true)
    #expect(ledger.snapshot().chargedBytes == 60)
    #expect(ledger.snapshot().materializedBytes == 60)
    #expect(ledger.snapshot().remainingBytes == 40)
}
