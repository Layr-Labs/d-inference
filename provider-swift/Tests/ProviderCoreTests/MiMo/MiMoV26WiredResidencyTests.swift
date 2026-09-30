// Copyright © 2026 Eigen Labs.
// Source-only host/policy tests; not native Metal or full-model qualification.
import Foundation
import MLX
import MLXVLM
import XCTest
@_spi(Benchmarking) @testable import ProviderCore

#if DEBUG
private actor MiMoWiringStartGate {
    private var entered = false
    private var released = false
    private var arrival: [CheckedContinuation<Void, Never>] = []
    private var held: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        let waiters = arrival; arrival = []
        for waiter in waiters { waiter.resume() }
        if !released { await withCheckedContinuation { held = $0 } }
    }
    func waitForEntry() async {
        if !entered { await withCheckedContinuation { arrival.append($0) } }
    }
    func release() {
        released = true
        let continuation = held; held = nil; continuation?.resume()
    }
}

final class MiMoV26WiredResidencyTests: XCTestCase {
    private let gib: UInt64 = 1 << 30

    func testOffDefaultAndReserveCeilings() {
        XCTAssertFalse(MiMoV26WiredResidency.isEnabled(environment: [:]))
        XCTAssertFalse(MiMoV26WiredResidency.isEnabled(environment: [
            MiMoV26WiredResidency.environmentFlag: "true"]))
        XCTAssertTrue(MiMoV26WiredResidency.isEnabled(environment: [
            MiMoV26WiredResidency.environmentFlag: "1"]))
        typealias Bounds = MiMoV26WiredResidency.Bounds
        XCTAssertEqual(Bounds(physicalBytes: 256 * gib, recommendedBytes: 243 * gib,
                              loadCapBytes: 240 * gib).safeCeiling,
                       Int(256 * gib - (256 * gib / 10 + 1)))
        XCTAssertEqual(Bounds(physicalBytes: 64 * gib, recommendedBytes: 48 * gib,
                              loadCapBytes: 60 * gib).safeCeiling, Int(48 * gib))
        XCTAssertEqual(Bounds(physicalBytes: 64 * gib, recommendedBytes: 48 * gib,
                              loadCapBytes: 40 * gib).safeCeiling, Int(40 * gib))
        XCTAssertNil(Bounds(physicalBytes: 16 * gib, recommendedBytes: 16 * gib,
                            loadCapBytes: 16 * gib).safeCeiling)
        XCTAssertNil(Bounds(physicalBytes: 0, recommendedBytes: 1, loadCapBytes: 1).safeCeiling)
    }

    func testAggregateClampOverflowAndPreExistingBaseline() {
        typealias Policy = MiMoV26WiredResidency.Policy
        XCTAssertEqual(Policy.summed([Int.max, 1]), Int.max)
        XCTAssertEqual(Policy.summed([-10, 8, 12]), 20)
        XCTAssertEqual(Policy.desired(baseline: 0, activeSizes: [60, 60], ceiling: 100), 100)
        XCTAssertEqual(Policy.desired(baseline: 90, activeSizes: [20], ceiling: 100), 90)
        XCTAssertEqual(Policy.desired(baseline: 200, activeSizes: [20], ceiling: 100), 200)
        let policy = Policy()
        XCTAssertTrue(policy.canAdmit(baseline: 0, activeSizes: [Int.max], newSize: Int.max))
    }

    private func manager() -> WiredMemoryManager {
        // Actual existing policy-only mode. No backend injection, Metal call,
        // baseline override, per-production-instance manager or global config.
        WiredMemoryManager.makeForTesting(configuration: .init(
            shrinkThresholdRatio: 0, shrinkCooldown: 0, policyOnlyWhenUnsupported: true,
            useRecommendedWorkingSetWhenUnsupported: false))
    }
    private func metadataTransaction() throws
        -> (MiMoV26NativeLoadRegistry, MiMoV26NativeLoadTransaction) {
        guard let path = ProcessInfo.processInfo.environment["MIMO_V26_WIRED_METADATA_FIXTURE"] else {
            throw XCTSkip("Point to an existing strict native metadata fixture; no weights are evaluated")
        }
        let budget = GlobalKVCacheBudget(capFraction: 0.90, activationReserveBytes: 1 << 30,
            configReserveBytes: 4 << 30, memorySnapshot: {
                .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: 64 << 30)
            })
        let load = try XCTUnwrap(MiMoV26ServingLoad.inspect(directory: URL(fileURLWithPath: path)))
        let registry = MiMoV26NativeLoadRegistry()
        let lifecycle = try registry.openLifecycle()
        try load.claim(budget: budget, lifecycle: lifecycle, registry: registry)
        return (registry, try XCTUnwrap(load.transaction))
    }
    private func receipt(_ owner: MiMoV26NativeLoadTransaction) async throws -> MiMoV26NativeRetirementReceipt {
        guard case .retired(let value) = await owner.retire() else {
            throw NSError(domain: "MiMoWiringHostTest.expectedActualRetirement", code: 1)
        }
        XCTAssertNil(value.engine)
        XCTAssertEqual(value.construction.completion, .noNativeSubmission)
        return value
    }

    func testTwoOwnersAggregateAndForeignPolicyRemainsUntouched() async throws {
        try await Device.withDefaultDevice(.cpu) {
            let (ra, a) = try metadataTransaction(), (rb, b) = try metadataTransaction()
            let policy = MiMoV26WiredResidency.Policy(), manager = manager()
            let first = MiMoV26WiredResidency.makeForPolicyOnlyTesting(
                transaction: a, residentPayloadBytes: 60, ceiling: { 100 }, policy: policy, manager: manager)
            let second = MiMoV26WiredResidency.makeForPolicyOnlyTesting(
                transaction: b, residentPayloadBytes: 60, ceiling: { 100 }, policy: policy, manager: manager)
            let one = await first.start(), two = await second.start()
            XCTAssertEqual(one.managerStartValue, 60)
            XCTAssertEqual(two.managerStartValue, 100) // truthful partial budget, not 120 wired
            XCTAssertTrue(two.policyOnlyTest)
            XCTAssertFalse(two.backendCoverageVerified)
            let foreign = WiredMemoryTicket(size: 200, policy: WiredMaxPolicy(), manager: manager)
            _ = await foreign.start()
            let retiredA = try await receipt(a)
            let endedA = await first.end(after: retiredA)
            XCTAssertEqual(endedA, .ended)
            XCTAssertEqual(first.snapshot().managerEndValue, 200)
            XCTAssertEqual(second.snapshot().phase, .held)
            XCTAssertEqual(policy.registeredCount, 1)
            let retiredB = try await receipt(b)
            let endedB = await second.end(after: retiredB)
            XCTAssertEqual(endedB, .ended)
            XCTAssertEqual(second.snapshot().managerEndValue, 200)
            XCTAssertEqual(policy.registeredCount, 0)
            XCTAssertFalse(second.snapshot().backendRestorationVerified)
            _ = await foreign.end()
            withExtendedLifetime((ra, rb, a, b, first, second)) {}
        }
    }

    func testCancellationAfterRealManagerStartWaitsForOwnedTaskJoin() async throws {
        try await Device.withDefaultDevice(.cpu) {
            let (registry, transaction) = try metadataTransaction()
            let manager = manager(), policy = MiMoV26WiredResidency.Policy(), gate = MiMoWiringStartGate()
            let owner = MiMoV26WiredResidency.makeForPolicyOnlyTesting(
                transaction: transaction, residentPayloadBytes: 64, ceiling: { 128 },
                policy: policy, manager: manager, afterManagerStart: { await gate.hold() })
            // This is the real registry-owned task, not a caller completion Boolean.
            let task = try registry.launchOwnedTask(for: transaction) { await owner.start() }
            await gate.waitForEntry() // manager start genuinely returned before hook
            XCTAssertEqual(owner.snapshot().phase, .starting)
            XCTAssertEqual(owner.snapshot().managerStartValue, 64)
            registry.cancel(transaction)
            guard case .pending(.ownedTasks) = await transaction.retire() else {
                return XCTFail("A cancelled but still-held acquisition must remain owned")
            }
            XCTAssertNil(owner.snapshot().managerEndValue)
            XCTAssertEqual(policy.registeredCount, 1)
            await gate.release()
            _ = await task.result
            await registry.joinOwnedTasksFromOutside(transaction)
            XCTAssertEqual(owner.snapshot().phase, .held)
            XCTAssertTrue(owner.snapshot().cancelledWhenStartReturned)
            let completed = try await receipt(transaction)
            let ended = await owner.end(after: completed)
            XCTAssertEqual(ended, .ended)
            XCTAssertEqual(owner.snapshot().managerEndValue, 0)
            let endedAgain = await owner.end(after: completed)
            XCTAssertEqual(endedAgain, .ended) // no duplicate manager.end
            XCTAssertEqual(policy.registeredCount, 0)
            withExtendedLifetime((registry, transaction, owner)) {}
        }
    }

    func testHostInjectedPostStartFaultRetainsTicketWithoutClaimingMetalFailureCoverage() async throws {
        try MiMoTestPrerequisites.requireOptIn("MIMO_V26_WIRED_HOST_FAULT_CASE")
        try await Device.withDefaultDevice(.cpu) {
            struct HostInjectedFault: Error {}
            let (registry, transaction) = try metadataTransaction()
            let policy = MiMoV26WiredResidency.Policy()
            let owner = MiMoV26WiredResidency.makeForPolicyOnlyTesting(
                transaction: transaction, residentPayloadBytes: 64, ceiling: { 128 },
                policy: policy, manager: manager(), afterManagerStart: { throw HostInjectedFault() })
            let started = await owner.start()
            XCTAssertEqual(started.phase, .retainedFault)
            XCTAssertEqual(started.managerStartValue, 64)
            XCTAssertNil(started.managerEndValue)
            XCTAssertFalse(started.backendCoverageVerified)
            let realHostReceipt = try await receipt(transaction)
            let ended = await owner.end(after: realHostReceipt)
            XCTAssertEqual(ended, .retainedFault)
            XCTAssertEqual(policy.registeredCount, 1)
            XCTAssertNil(owner.snapshot().managerEndValue)
            // Sticky test-only owner, just as the production registry retains
            // a real failed owner. No backend error/restoration pass is claimed.
            _ = Unmanaged.passRetained(owner)
            withExtendedLifetime((registry, transaction)) {}
        }
    }

    func testForeignTrueReceiptCannotEndAnotherOwnersTicket() async throws {
        try await Device.withDefaultDevice(.cpu) {
            let (ra, a) = try metadataTransaction(), (rb, b) = try metadataTransaction()
            let policy = MiMoV26WiredResidency.Policy()
            let owner = MiMoV26WiredResidency.makeForPolicyOnlyTesting(
                transaction: a, residentPayloadBytes: 64, ceiling: { 128 }, policy: policy, manager: manager())
            _ = await owner.start()
            let foreign = try await receipt(b)
            let refused = await owner.end(after: foreign)
            XCTAssertEqual(refused, .foreignReceipt)
            XCTAssertEqual(owner.snapshot().phase, .held)
            XCTAssertNil(owner.snapshot().managerEndValue)
            let actual = try await receipt(a)
            let ended = await owner.end(after: actual)
            XCTAssertEqual(ended, .ended)
            withExtendedLifetime((ra, rb, a, b, owner)) {}
        }
    }
}
#endif
