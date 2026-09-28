import Dispatch
import Foundation
import MLXLMCommon
import XCTest
@testable import MLXVLM
@testable import ProviderCore

/// Real ledger and real metadata-created SDK session requests. Usage/progress
/// and receipt values are controlled arithmetic inputs, NOT proof of native
/// materialization. No test below evaluates model arrays or calls a successful
/// native load. Root's explicit fixture run must report zero skips.
private final class MiMoPermitUsage: @unchecked Sendable {
    private let lock = NSLock()
    private var active: UInt64 = 0
    private var cache: UInt64 = 0
    private var available: UInt64 = .max
    func set(active: UInt64 = 0, cache: UInt64 = 0, available: UInt64 = .max) {
        lock.withLock { self.active = active; self.cache = cache; self.available = available }
    }
    func read() -> ProcessMemoryLedger.Usage {
        lock.withLock { .init(activeBytes: active, cacheBytes: cache, systemAvailableBytes: available) }
    }
    func budgetRead() -> GlobalKVCacheBudget.MemorySnapshot {
        lock.withLock { .init(total: 32 << 30, active: active, cache: cache, systemAvailable: available) }
    }
}

private final class MiMoPermitResults: @unchecked Sendable {
    private let lock = NSLock()
    private var permits: [MiMoV26PendingLoadReservation] = []
    private var errors = 0
    func keep(_ permit: MiMoV26PendingLoadReservation) { lock.withLock { permits.append(permit) } }
    func failed() { lock.withLock { errors += 1 } }
    func result() -> ([MiMoV26PendingLoadReservation], Int) { lock.withLock { (permits, errors) } }
}

private struct MiMoPermitFixture {
    let plan: MiMoV26FilesystemLoadPlan
    let session: MiMoV26SerialLoadSession
    let prefixes: [UInt64]
    var request: MiMoV26SerialLoadRequest { session.request }
    var count: Int { request.binding.estimate.tensorCount }
    var payload: UInt64 { UInt64(request.binding.tensorBytes) }
    var initialCharge: UInt64 { request.requiredLoadBytes + UnifiedMemoryCap.minimumLoadKVBytes }

    init() throws {
        guard let directory = ProcessInfo.processInfo.environment["MIMO_V26_SERIAL_LOAD_FIXTURES"] else {
            throw XCTSkip("Set MIMO_V26_SERIAL_LOAD_FIXTURES to the synthetic BF16 metadata fixture; explicit qualification requires zero skips")
        }
        let root = URL(fileURLWithPath: directory)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(contentsOf: root.appendingPathComponent("provenance.json"))) as? [String: String])
        let provenance = try MiMoV26ConvertedProvenance(artifactID: XCTUnwrap(raw["artifactID"]),
            sourceRepository: XCTUnwrap(raw["sourceRepository"]), sourceRevision: XCTUnwrap(raw["sourceRevision"]),
            conversionManifestSHA256: XCTUnwrap(raw["conversionManifestSHA256"]))
        plan = try MiMoV26FilesystemWeights.preflight(root: root.appendingPathComponent("tiny-bf16"),
            provenance: provenance, limits: .init(maximumShardBytes: 1_048_576, maximumTotalFileBytes: 4_194_304))
        session = try MiMoV26SerialLoadSession(plan: plan)
        var values: [UInt64] = [0]
        for shard in plan.shards {
            for tensor in shard.tensorLocations { values.append(values.last! + UInt64(tensor.byteCount)) }
        }
        prefixes = values
        XCTAssertEqual(prefixes.count, request.binding.estimate.tensorCount + 1)
        XCTAssertEqual(prefixes.last, payload)
    }

    func progress(_ phase: MiMoV26SerialLoadPhase, sources: Int = 0, parameters: Int = 0) -> MiMoV26SerialLoadProgress {
        .init(phase: phase, sourceTensorsCompleted: sources, sourceTensorCount: count,
              materializedSourcePayloadBytes: prefixes[sources], parametersCompleted: parameters,
              parameterCount: phase == .parameterMaterialization || phase == .complete ? count : 0,
              currentShard: nil, currentTensor: nil)
    }
    func receipt(for request: MiMoV26SerialLoadRequest? = nil, parameters: Int? = nil) -> MiMoV26SerialLoadReceipt {
        let value = request ?? self.request
        return .init(sessionID: value.sessionID, binding: value.binding, sourceTensorCount: count,
                     parameterCount: parameters ?? count, materializedSourcePayloadBytes: payload)
    }
}

final class MiMoV26PendingLoadReservationTests: XCTestCase {
    private let activation: UInt64 = 256 << 20
    private let osReserve: UInt64 = 64 << 20
    private func makeLedger(_ usage: MiMoPermitUsage, cap: UInt64) -> ProcessMemoryLedger {
        .init(policy: .init(epoch: 1, capBytes: cap, reserveBytes: activation), readUsage: usage.read)
    }
    private func claim(_ f: MiMoPermitFixture, _ ledger: ProcessMemoryLedger) throws -> MiMoV26PendingLoadReservation {
        try .init(ledger: ledger, request: f.request, loadReserveBytes: osReserve)
    }
    private func begin(_ permit: MiMoV26PendingLoadReservation, _ f: MiMoPermitFixture) throws {
        try permit.validateActive(progress: f.progress(.admitted))
        try permit.validateActive(progress: f.progress(.sourceHandles))
        try permit.validateActive(progress: f.progress(.sourceMaterialization))
    }
    private func completeProgress(_ permit: MiMoV26PendingLoadReservation, _ f: MiMoPermitFixture, _ usage: MiMoPermitUsage) throws {
        try begin(permit, f)
        usage.set(active: f.payload)
        try permit.validateActive(progress: f.progress(.parameterMaterialization, sources: f.count))
        try permit.validateActive(progress: f.progress(.complete, sources: f.count, parameters: f.count))
    }
    private func failAndDrain(_ permit: MiMoV26PendingLoadReservation) throws {
        permit.revoke()
        XCTAssertTrue(try permit.finishFailureAfterNativeDrain())
    }

    private func requireNoNativeSubmission(_ scope: NativeConstructionScope) throws {
        let actual: NativeConstructionReceipt?
        if case .completed(let receipt) = scope.snapshot.disposition,
           receipt.completion == .noNativeSubmission {
            actual = receipt
        } else {
            actual = nil
        }
        // Stop before controlled ledger retirement if the real SDK did not
        // prove this metadata-only refusal. Never manufacture a receipt.
        try scope.validate(try XCTUnwrap(actual, "Expected actual no-submission completion"))
    }

    func testRealLedgerClaimHonorsOtherOwnerAndExtraOSReserve() throws {
        let f = try MiMoPermitFixture(), usage = MiMoPermitUsage()
        let otherBytes: UInt64 = 1234
        let cap = f.initialCharge + otherBytes + activation
        let ledger = makeLedger(usage, cap: cap)
        let empty = ledger.createOwner()
        let other = try ledger.replaceCharge(owner: empty.owner, expectedRevision: empty.revision,
            expectedPolicyEpoch: 1, chargedBytes: otherBytes)
        usage.set(available: cap + osReserve - 1)
        XCTAssertThrowsError(try claim(f, ledger)) {
            XCTAssertEqual($0 as? ProcessMemoryLedger.Refusal, .insufficientCapacity)
        }
        XCTAssertEqual(ledger.snapshot().ownerCount, 1, "failed claim must retire its empty owner")
        usage.set(available: cap + osReserve)
        let permit = try claim(f, ledger)
        XCTAssertEqual(permit.reservedLoadBytes, f.request.requiredLoadBytes)
        XCTAssertEqual(permit.snapshot().ownerState?.chargedBytes, f.initialCharge)
        XCTAssertEqual(ledger.snapshot().chargedBytes, f.initialCharge + otherBytes)
        XCTAssertEqual(ledger.snapshot().materializedBytes, 0)
        try failAndDrain(permit)
        XCTAssertEqual(ledger.state(for: other.owner), other)
        _ = try ledger.replaceCharge(owner: other.owner, expectedRevision: other.revision,
            expectedPolicyEpoch: 0, chargedBytes: 0)
        _ = ledger.retire(other.owner)
    }

    func testProofReducesFuturePromiseWithoutCoverageOrDoubleTax() throws {
        let f = try MiMoPermitFixture(), usage = MiMoPermitUsage()
        let cap = f.initialCharge + activation
        usage.set(available: cap + osReserve)
        let ledger = makeLedger(usage, cap: cap), permit = try claim(f, ledger)
        try begin(permit, f)
        let count = min(64, f.count - 1), bytes = f.prefixes[count]
        usage.set(active: bytes, available: cap + osReserve - bytes)
        XCTAssertEqual(ledger.snapshot().commitmentDebtBytes, bytes)
        try permit.validateActive(progress: f.progress(.sourceMaterialization, sources: count))
        let state = permit.snapshot()
        XCTAssertEqual(state.ownerState?.chargedBytes, f.initialCharge - bytes)
        XCTAssertEqual(state.ownerState?.materializedBytes, 0)
        XCTAssertEqual(state.provedSourcePayloadBytes, bytes)
        XCTAssertEqual(ledger.snapshot().commitmentDebtBytes, 0)
        try permit.validateActive(progress: f.progress(.sourceMaterialization, sources: count))
        XCTAssertEqual(permit.snapshot().ownerState, state.ownerState, "duplicate SDK validation cannot refund twice")
        XCTAssertThrowsError(try permit.validateActive(progress: f.progress(.sourceMaterialization, sources: count - 1)))
        XCTAssertEqual(permit.snapshot().lifecycle, .revoked)
        XCTAssertEqual(ledger.snapshot().chargedBytes, f.initialCharge - bytes)
        XCTAssertTrue(try permit.finishFailureAfterNativeDrain())
    }

    func testUnrelatedUsageDropIsNotUsedAsMaterializationDelta() throws {
        let f = try MiMoPermitFixture(), usage = MiMoPermitUsage()
        let unrelated: UInt64 = 512 << 20
        let ledger = makeLedger(usage, cap: f.initialCharge + activation + unrelated)
        usage.set(active: unrelated)
        let permit = try claim(f, ledger)
        try begin(permit, f)
        let count = min(64, f.count - 1), bytes = f.prefixes[count]
        usage.set(active: bytes) // Another workload disappeared; net process delta is negative.
        try permit.validateActive(progress: f.progress(.sourceMaterialization, sources: count))
        XCTAssertEqual(permit.snapshot().ownerState?.chargedBytes, f.initialCharge - bytes)
        XCTAssertEqual(ledger.snapshot().materializedBytes, 0)
        try failAndDrain(permit)
    }

    func testCachedOrUnreflectedBytesDoNotSatisfyRetainedSourceProof() throws {
        let f = try MiMoPermitFixture(), usage = MiMoPermitUsage()
        let ledger = makeLedger(usage, cap: f.initialCharge + activation + (1 << 20))
        let permit = try claim(f, ledger)
        try begin(permit, f)
        let count = min(64, f.count - 1), bytes = f.prefixes[count]
        usage.set(active: 0, cache: bytes)
        XCTAssertThrowsError(try permit.validateActive(progress: f.progress(.sourceMaterialization, sources: count))) {
            XCTAssertEqual($0 as? MiMoV26PendingLoadError, .usageNotReflected)
        }
        XCTAssertEqual(permit.snapshot().lifecycle, .revoked)
        XCTAssertEqual(ledger.snapshot().chargedBytes, f.initialCharge)
        XCTAssertEqual(ledger.snapshot().closingOwnerCount, 1)
        XCTAssertEqual(ledger.snapshot().materializedBytes, 0)
        XCTAssertTrue(try permit.finishFailureAfterNativeDrain())
    }

    func testPolicyEpochChangesRecheckCurrentCapacityAndRetainOnRefusal() throws {
        let f = try MiMoPermitFixture(), usage = MiMoPermitUsage()
        let cap = f.initialCharge + activation
        let ledger = makeLedger(usage, cap: cap), permit = try claim(f, ledger)
        try permit.recheck(for: f.request)
        XCTAssertTrue(ledger.updatePolicy(.init(epoch: 2, capBytes: cap, reserveBytes: activation)))
        try permit.recheck(for: f.request)
        XCTAssertEqual(permit.snapshot().lastPolicyEpoch, 2)
        XCTAssertTrue(ledger.updatePolicy(.init(epoch: 3, capBytes: cap - 1, reserveBytes: activation)))
        XCTAssertThrowsError(try permit.recheck(for: f.request)) {
            XCTAssertEqual($0 as? ProcessMemoryLedger.Refusal, .insufficientCapacity)
        }
        XCTAssertEqual(ledger.snapshot().chargedBytes, f.initialCharge)
        XCTAssertEqual(permit.reservedLoadBytes, 0)
        XCTAssertTrue(try permit.finishFailureAfterNativeDrain(), "real drain may retire even under policy debt")
        XCTAssertFalse(try permit.finishFailureAfterNativeDrain())
        XCTAssertEqual(ledger.snapshot().ownerCount, 0)
    }

    func testCompleteCallbackIsNotReceiptAndSetupRetiresExplicitlyOnce() throws {
        let f = try MiMoPermitFixture(), usage = MiMoPermitUsage()
        let ledger = makeLedger(usage, cap: f.initialCharge + activation + (1 << 20))
        let permit = try claim(f, ledger)
        try completeProgress(permit, f, usage)
        XCTAssertEqual(permit.snapshot().lifecycle, .loading)
        XCTAssertEqual(permit.snapshot().ownerState?.chargedBytes, f.initialCharge - f.payload)
        XCTAssertThrowsError(try permit.finishSetupAfterAccounting())
        let other = try MiMoV26SerialLoadSession(plan: f.plan).request
        XCTAssertThrowsError(try permit.settleReturnedReceipt(f.receipt(for: other)))
        XCTAssertThrowsError(try permit.settleReturnedReceipt(f.receipt(parameters: f.count - 1)))
        XCTAssertTrue(try permit.settleReturnedReceipt(f.receipt()))
        XCTAssertFalse(try permit.settleReturnedReceipt(f.receipt()))
        XCTAssertEqual(permit.snapshot().lifecycle, .setup)
        XCTAssertEqual(ledger.snapshot().chargedBytes, UnifiedMemoryCap.minimumLoadKVBytes)
        XCTAssertEqual(ledger.snapshot().materializedBytes, 0)
        try permit.recheck(for: f.request)
        XCTAssertTrue(try permit.finishSetupAfterAccounting())
        XCTAssertFalse(try permit.finishSetupAfterAccounting())
        XCTAssertEqual(ledger.snapshot().ownerCount, 0)
        XCTAssertThrowsError(try permit.recheck(for: f.request))
    }

    func testRevocationAfterSuccessfulLoadStillHoldsSetupUntilFailureDrain() throws {
        let f = try MiMoPermitFixture(), usage = MiMoPermitUsage()
        let ledger = makeLedger(usage, cap: f.initialCharge + activation + (1 << 20))
        let permit = try claim(f, ledger)
        try completeProgress(permit, f, usage)
        XCTAssertTrue(try permit.settleReturnedReceipt(f.receipt()))
        permit.revoke(); permit.revoke()
        XCTAssertEqual(ledger.snapshot().chargedBytes, UnifiedMemoryCap.minimumLoadKVBytes)
        XCTAssertEqual(ledger.snapshot().closingOwnerCount, 1)
        XCTAssertThrowsError(try permit.validateActive(progress: f.progress(.complete, sources: f.count, parameters: f.count)))
        XCTAssertTrue(try permit.finishFailureAfterNativeDrain())
        XCTAssertEqual(ledger.snapshot().ownerCount, 0)
    }

    func testConcurrentClaimsAndCallbacksHaveOneOwnerAndOneReduction() throws {
        let f = try MiMoPermitFixture(), usage = MiMoPermitUsage()
        let ledger = makeLedger(usage, cap: f.initialCharge * 4 + activation)
        let results = MiMoPermitResults(), request = f.request, reserve = osReserve
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            do { results.keep(try .init(ledger: ledger, request: request, loadReserveBytes: reserve)) }
            catch { results.failed() }
        }
        let values = results.result()
        XCTAssertEqual(values.0.count, 1); XCTAssertEqual(values.1, 15)
        XCTAssertEqual(ledger.snapshot().ownerCount, 1)
        let permit = try XCTUnwrap(values.0.first)
        func sendable<T: Sendable>(_ value: T) {}
        sendable(permit)
        try begin(permit, f)
        let count = min(64, f.count - 1), progress = f.progress(.sourceMaterialization, sources: count)
        usage.set(active: f.prefixes[count])
        let callbacks = MiMoPermitResults()
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            do { try permit.validateActive(progress: progress) }
            catch { callbacks.failed() }
        }
        XCTAssertEqual(callbacks.result().1, 0)
        XCTAssertEqual(ledger.snapshot().chargedBytes, f.initialCharge - f.prefixes[count])
        XCTAssertEqual(ledger.snapshot().materializedBytes, 0)
        try failAndDrain(permit)
    }

    func testLateCleanupCannotClearSuccessorClaimAndSDKOwnsOneShot() throws {
        let f = try MiMoPermitFixture(), usage = MiMoPermitUsage()
        let ledger = makeLedger(usage, cap: f.initialCharge * 3 + activation)
        let first = try claim(f, ledger)
        XCTAssertThrowsError(try claim(f, ledger))
        try failAndDrain(first)
        let successor = try claim(f, ledger)
        XCTAssertFalse(try first.finishFailureAfterNativeDrain())
        first.revoke()
        XCTAssertThrowsError(try claim(f, ledger)) {
            XCTAssertEqual($0 as? MiMoV26PendingLoadError, .duplicateClaim)
        }
        XCTAssertEqual(ledger.snapshot().ownerCount, 1)
        let foreign = try MiMoV26SerialLoadSession(plan: f.plan)
        XCTAssertThrowsError(try successor.recheck(for: foreign.request))
        let mismatchScope = NativeConstructionScope(), consumedScope = NativeConstructionScope()
        defer {
            // Unexpected failed native completion keeps its actual owners
            // until this test process exits; no in-process recovery is implied.
            for scope in [mismatchScope, consumedScope] where scope.snapshot.isRetainedFault {
                _ = Unmanaged.passRetained(scope)
            }
        }
        // Both SDK failures happen before native handle/module construction.
        XCTAssertThrowsError(try foreign.load(reservation: successor, retaining: mismatchScope)) {
            XCTAssertEqual($0 as? MiMoV26SerialLoadError, .reservationMismatch)
        }
        try requireNoNativeSubmission(mismatchScope)
        try failAndDrain(successor)
        let retry = try MiMoV26PendingLoadReservation(ledger: ledger, request: foreign.request, loadReserveBytes: osReserve)
        XCTAssertThrowsError(try foreign.load(reservation: retry, retaining: consumedScope)) {
            XCTAssertEqual($0 as? MiMoV26SerialLoadError, .alreadyConsumed)
        }
        try requireNoNativeSubmission(consumedScope)
        try failAndDrain(retry)
        XCTAssertEqual(ledger.snapshot().ownerCount, 0)
    }

    func testDroppingWrapperDoesNotRefundOrPermitDualCharge() throws {
        let f = try MiMoPermitFixture(), usage = MiMoPermitUsage()
        let ledger = makeLedger(usage, cap: f.initialCharge * 3 + activation)
        var permit: MiMoV26PendingLoadReservation? = try claim(f, ledger)
        weak var witness = permit
        let orphan = try XCTUnwrap(permit?.snapshot().ownerState)
        permit = nil
        XCTAssertNil(witness)
        XCTAssertEqual(ledger.snapshot().chargedBytes, f.initialCharge)
        XCTAssertThrowsError(try claim(f, ledger), "dead weak ticket cannot erase an unreleased real owner")
        // Controlled ledger retirement of this synthetic orphan proves stale
        // weak metadata is pruned; production callers must retain their permit.
        _ = try ledger.replaceCharge(owner: orphan.owner, expectedRevision: orphan.revision,
            expectedPolicyEpoch: 0, chargedBytes: 0)
        _ = ledger.retire(orphan.owner)
        let next = try claim(f, ledger)
        try failAndDrain(next)
    }

    func testStaleRevisionMalformedProgressAndOverflowNeverMintCoverage() throws {
        let f = try MiMoPermitFixture(), usage = MiMoPermitUsage()
        let ledger = makeLedger(usage, cap: f.initialCharge + activation + (1 << 20))
        XCTAssertThrowsError(try MiMoV26PendingLoadReservation(ledger: ledger, request: f.request,
            loadReserveBytes: osReserve, setupKVBytes: 0))
        XCTAssertThrowsError(try MiMoV26PendingLoadReservation(ledger: ledger, request: f.request,
            loadReserveBytes: osReserve, setupKVBytes: .max)) {
            XCTAssertEqual($0 as? MiMoV26PendingLoadError, .arithmeticOverflow)
        }
        XCTAssertEqual(ledger.snapshot().ownerCount, 0)
        let permit = try claim(f, ledger)
        let original = try XCTUnwrap(permit.snapshot().ownerState)
        _ = try ledger.replaceCharge(owner: original.owner, expectedRevision: original.revision,
            expectedPolicyEpoch: 1, chargedBytes: original.chargedBytes + 1)
        XCTAssertThrowsError(try permit.recheck(for: f.request)) {
            XCTAssertEqual($0 as? ProcessMemoryLedger.Refusal, .staleRevision)
        }
        XCTAssertEqual(ledger.snapshot().chargedBytes, original.chargedBytes + 1)
        XCTAssertTrue(try permit.finishFailureAfterNativeDrain())
        let malformed = try claim(f, ledger)
        XCTAssertThrowsError(try malformed.validateActive(progress:
            f.progress(.complete, sources: f.count, parameters: f.count)))
        XCTAssertEqual(ledger.snapshot().chargedBytes, f.initialCharge)
        XCTAssertEqual(ledger.snapshot().materializedBytes, 0)
        XCTAssertTrue(try malformed.finishFailureAfterNativeDrain())
    }

    func testNonisolatedFactoryUsesSharedLedgerWithoutActorRecordRevisionMutation() async throws {
        let f = try MiMoPermitFixture(), usage = MiMoPermitUsage()
        let budget = GlobalKVCacheBudget(activationReserveBytes: activation, memorySnapshot: usage.budgetRead)
        let accepted = await budget.reserveBytes(requestID: "other", bytes: 4096)
        XCTAssertTrue(accepted)
        let permit = try budget.reserveMiMoV26PendingLoad(for: f.request)
        XCTAssertEqual(budget.memoryHeadroomSnapshot().ownerCount, 2)
        try begin(permit, f)
        let count = min(64, f.count - 1)
        usage.set(active: f.prefixes[count])
        try permit.validateActive(progress: f.progress(.sourceMaterialization, sources: count))
        let actorIDs = await budget.reservationIDsForTesting()
        XCTAssertEqual(actorIDs, ["other"])
        await budget.release(requestID: "other") // Its actor-owned revision must still be current.
        XCTAssertEqual(budget.memoryHeadroomSnapshot().ownerCount, 1)
        try failAndDrain(permit)
        XCTAssertEqual(budget.memoryHeadroomSnapshot().ownerCount, 0)
    }
}
