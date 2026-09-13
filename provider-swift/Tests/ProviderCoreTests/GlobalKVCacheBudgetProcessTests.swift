import Foundation
import Testing
@testable import ProviderCore

private let processBudgetGiB: UInt64 = 1 << 30

private final class ProcessBudgetUsage: @unchecked Sendable {
    private let lock = NSLock()
    private var value: GlobalKVCacheBudget.MemorySnapshot

    init(total: UInt64 = 8 << 30, active: UInt64 = 0, available: UInt64 = .max) {
        value = .init(total: total, active: active, cache: 0, systemAvailable: available)
    }

    func setActive(_ bytes: UInt64) { lock.withLock { value.active = bytes } }
    func setAvailable(_ bytes: UInt64) { lock.withLock { value.systemAvailable = bytes } }
    func read() -> GlobalKVCacheBudget.MemorySnapshot { lock.withLock { value } }
}

@Test func processBudgetNativeCoverageKeepsLoadHeadroomExact() async throws {
    let cap = 6 * processBudgetGiB
    let usage = ProcessBudgetUsage(active: cap - 100)
    let budget = GlobalKVCacheBudget(
        capFraction: 1, activationReserveBytes: 0, memorySnapshot: usage.read)
    let native = budget.makeEngineMemoryOwner()
    try native.replaceCharge(60)
    usage.setActive(cap - 60)
    try native.recordMaterialization(40)
    #expect(budget.memoryHeadroomSnapshot().totalOwnedBytes == 60)
    #expect(budget.memoryHeadroomSnapshot().unmaterializedCommittedBytes == 20)
    #expect(budget.availableForLoadGb() == Double(40) / Double(processBudgetGiB))
    let load = try #require(await budget.claimPendingLoad(
        requestID: "load", weightBytes: 40, minimumKVBytes: 0))
    #expect(await budget.claimPendingLoad(
        requestID: "too-large", weightBytes: 1, minimumKVBytes: 0) == nil)
    #expect(await budget.finishPendingLoad(load))
    try native.withdrawCoverage(40)
    usage.setActive(cap - 100)
    try native.replaceCharge(0)
    native.retire()
    #expect(budget.memoryHeadroomSnapshot().ownerCount == 0)
}

@Test func processBudgetLoadReservePreservesOSLimitedPolicyWithoutChangingRuntime() async throws {
    let usage = ProcessBudgetUsage(available: 2 * processBudgetGiB + 100)
    let budget = GlobalKVCacheBudget(
        capFraction: 1, activationReserveBytes: 0, memorySnapshot: usage.read)
    #expect(budget.availableForLoadGb() == Double(100) / Double(processBudgetGiB))
    #expect(await budget.claimPendingLoad(
        requestID: "over", weightBytes: 101, minimumKVBytes: 0) == nil)
    let load = try #require(await budget.claimPendingLoad(
        requestID: "fits", weightBytes: 100, minimumKVBytes: 0))
    #expect(await budget.recheckPendingLoad(load))
    usage.setAvailable(2 * processBudgetGiB + 99)
    #expect(!(await budget.recheckPendingLoad(load)))
    #expect(await budget.outstandingReservedBytes() == 100)
    // The stricter load constraint is admission-time only. Ordinary runtime
    // claims continue to use the established min(effectiveCap-U, OSfree) policy.
    #expect(await budget.reserveBytes(requestID: "runtime", bytes: 2 * processBudgetGiB - 1))
    await budget.release(requestID: "runtime")
    #expect(await budget.finishPendingLoad(load))
}

@Test func processBudgetLoadAllowanceSurvivesTargetAndAssistantPhaseCompletion() async throws {
    let cap = 6 * processBudgetGiB
    let usage = ProcessBudgetUsage(active: cap - 100)
    let budget = GlobalKVCacheBudget(
        capFraction: 1, activationReserveBytes: 0, memorySnapshot: usage.read)
    let load = try #require(await budget.claimPendingLoad(
        requestID: "load", weightBytes: 80, minimumKVBytes: 20))
    #expect(!(await budget.reserveBytes(requestID: "competitor", bytes: 1)))
    usage.setActive(cap - 40) // Target60 now resident; assistant20 still pending.
    #expect(await budget.reducePendingLoad(load, remainingWeightBytes: 20))
    #expect(await budget.outstandingReservedBytes() == 40)
    usage.setActive(cap - 20) // Assistant20 now resident.
    #expect(await budget.reducePendingLoad(load, remainingWeightBytes: 0))
    #expect(await budget.outstandingReservedBytes() == 20)
    #expect(!(await budget.reserveBytes(requestID: "competitor", bytes: 1)))
    #expect(await budget.finishPendingLoad(load)) // Setup allowance ends here.
    #expect(await budget.reserveBytes(requestID: "competitor", bytes: 20))
    await budget.release(requestID: "competitor")
    #expect(budget.memoryHeadroomSnapshot().ownerCount == 0)
}

@Test func processBudgetDelayedLoadCleanupCannotCloseSameIDSuccessor() async throws {
    let usage = ProcessBudgetUsage()
    let budget = GlobalKVCacheBudget(
        capFraction: 1, activationReserveBytes: 0, memorySnapshot: usage.read)
    let old = try #require(await budget.claimPendingLoad(
        requestID: "pending-load:same", weightBytes: 100, minimumKVBytes: 0))
    #expect(await budget.claimPendingLoad(
        requestID: "pending-load:same", weightBytes: 100, minimumKVBytes: 0) == nil)
    #expect(await budget.finishPendingLoad(old))
    let next = try #require(await budget.claimPendingLoad(
        requestID: "pending-load:same", weightBytes: 200, minimumKVBytes: 0))
    #expect(!(await budget.finishPendingLoad(old)))
    #expect(!(await budget.reducePendingLoad(old, remainingWeightBytes: 0)))
    #expect(!(await budget.recheckPendingLoad(old)))
    await budget.release(requestID: "pending-load:same") // Untyped release has no authority.
    #expect(await budget.outstandingReservedBytes() == 200)
    #expect(await budget.finishPendingLoad(next))
    #expect(await budget.reservationIDsForTesting().isEmpty)
}

@Test func processBudgetPolicyRecheckRetainsTheWholeAcceptedLoad() async throws {
    let usage = ProcessBudgetUsage(
        total: 24 * processBudgetGiB, active: UInt64(1.9 * Double(processBudgetGiB)))
    let budget = GlobalKVCacheBudget(
        capFraction: 1, activationReserveBytes: UInt64(3.5 * Double(processBudgetGiB)),
        configReserveBytes: 4 * processBudgetGiB, memorySnapshot: usage.read)
    let weightBytes = UInt64(13.5 * Double(processBudgetGiB))
    let load = try #require(await budget.claimPendingLoad(requestID: "target", weightBytes: weightBytes))
    #expect(await budget.recheckPendingLoad(load))
    await budget.setActivationReserveBytes(UInt64(5.5 * Double(processBudgetGiB)), epoch: 1)
    #expect(!(await budget.recheckPendingLoad(load)))
    #expect(await budget.outstandingReservedBytes() == weightBytes + processBudgetGiB)
    #expect(await budget.finishPendingLoad(load))
    #expect(budget.memoryHeadroomSnapshot().ownerCount == 0)
}

@Test func processBudgetOptionalAssistantCannotSpendTargetOnlyHeadroom() async throws {
    let usage = ProcessBudgetUsage(
        total: 24 * processBudgetGiB, active: UInt64(1.8 * Double(processBudgetGiB)))
    let budget = GlobalKVCacheBudget(
        capFraction: 1, activationReserveBytes: UInt64(3.5 * Double(processBudgetGiB)),
        configReserveBytes: 4 * processBudgetGiB, memorySnapshot: usage.read)
    #expect(await budget.claimPendingLoad(requestID: "load", weightBytes: 14 * processBudgetGiB) == nil)
    let target = try #require(await budget.claimPendingLoad(
        requestID: "load", weightBytes: UInt64(13.5 * Double(processBudgetGiB))))
    #expect(await budget.recheckPendingLoad(target))
    #expect(await budget.finishPendingLoad(target))
}

@Test func processBudgetLoadClaimAndNativeGrowthCompeteAtOneLock() async throws {
    let cap = 6 * processBudgetGiB
    let usage = ProcessBudgetUsage(active: cap - 100)
    let budget = GlobalKVCacheBudget(
        capFraction: 1, activationReserveBytes: 0, memorySnapshot: usage.read)
    let native = budget.makeEngineMemoryOwner()
    async let loadClaim = budget.claimPendingLoad(
        requestID: "load", weightBytes: 100, minimumKVBytes: 0)
    async let nativeClaim = Task.detached {
        do { try native.replaceCharge(100); return true }
        catch { return false }
    }.value
    let (load, nativeAccepted) = await (loadClaim, nativeClaim)
    #expect((load != nil ? 1 : 0) + (nativeAccepted ? 1 : 0) == 1)
    #expect(await budget.outstandingReservedBytes() == 100)
    if let load { #expect(await budget.finishPendingLoad(load)) }
    if nativeAccepted { try native.replaceCharge(0) }
    native.retire()
    #expect(budget.memoryHeadroomSnapshot().ownerCount == 0)
}

@Test func processBudgetNativeClosingKeepsPreviouslyReservedAllocationsSafe() throws {
    let cap = 6 * processBudgetGiB
    let usage = ProcessBudgetUsage(active: cap - 100)
    let budget = GlobalKVCacheBudget(
        capFraction: 1, activationReserveBytes: 0, memorySnapshot: usage.read)
    let native = budget.makeEngineMemoryOwner()
    try native.replaceCharge(100)
    native.retire()
    #expect(throws: ProcessMemoryLedger.Refusal.ownerClosing) { try native.replaceCharge(101) }
    usage.setActive(cap)
    try native.recordMaterialization(100)
    try native.withdrawCoverage(100)
    usage.setActive(cap - 100)
    try native.replaceCharge(0)
    #expect(native.snapshot() == nil)
    // Native Admission must suppress unchanged zero publications after its
    // owner disappears. The real adapter must not turn stale generations into
    // successful writes or create a replacement owner during empty teardown.
    #expect(throws: ProcessMemoryLedger.Refusal.unknownOwner) { try native.replaceCharge(0) }
    #expect(throws: ProcessMemoryLedger.Refusal.unknownOwner) { try native.replaceCharge(1) }
    #expect(throws: ProcessMemoryLedger.Refusal.unknownOwner) { try native.withdrawCoverage(0) }
    native.retire()
    #expect(budget.memoryHeadroomSnapshot().ownerCount == 0)
}
