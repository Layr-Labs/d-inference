import Foundation
import XCTest
@testable import MLXVLM
@testable import ProviderCore

/// Actual ledger arithmetic with metadata-only plans. No decoder, native work,
/// feature arrays, allocator oracle or claim of native retirement.
final class MiMoV26MediaPhaseAdmissionTests: XCTestCase {
    private final class Usage: @unchecked Sendable {
        private let lock = NSLock()
        private var available: UInt64 = 1 << 20
        private var preparation: (@Sendable () -> Void)?
        func setAvailable(_ value: UInt64) { lock.withLock { available = value } }
        func armPreparation(_ action: @escaping @Sendable () -> Void) {
            lock.withLock { preparation = action }
        }
        func prepare() {
            let action = lock.withLock { let value = preparation; preparation = nil; return value }
            action?()
        }
        func read() -> ProcessMemoryLedger.Usage {
            lock.withLock { .init(activeBytes: 0, cacheBytes: 0, systemAvailableBytes: available) }
        }
    }
    private func plan() -> MiMoV26MultimodalPlan {
        .init(promptTokens: [1], spans: [], maximumOutputTokens: 1,
            preparationSHA256: "phase-growth", profile: "metadata-only",
            loadedOwnerIdentity: UUID(), configurationSHA256: "config",
            templateSHA256: "template", visionGeometryByMediaIndex: [:], audioPlan: nil,
            decodedElements: 0, patchElements: 0, featureElements: 0,
            logicalFeatureBytes: 0, processorIdentity: UUID(), parts: [])
    }
    private func fixture() throws -> (Usage, ProcessMemoryLedger, MiMoV26ManagedMediaReservation) {
        let usage = Usage()
        let ledger = ProcessMemoryLedger(policy: .init(epoch: 1, capBytes: 1 << 20, reserveBytes: 0),
            prepareUsage: { usage.prepare() },
            readUsage: { usage.read() })
        let reservation = try MiMoV26ManagedMediaReservation(initialBytes: 4096, hostBytes: 1024,
            maximumBytes: 16384, additionalSystemReserveBytes: 1, ledger: ledger)
        return (usage, ledger, reservation)
    }
    private func assertOrdinary(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(error as? MiMoV26MultimodalError, .reservationRejected, file: file, line: line)
        let outward = MiMoV26EncodedMediaIngress.outwardFailure(error)
        XCTAssertEqual(ProviderLoop.mapInferenceErrorToStatus(outward), 503, file: file, line: line)
    }

    func testInitialCapacityRefusalIsOrdinaryAndRetiresOnlyItsColdOwner() throws {
        let usage = Usage()
        let ledger = ProcessMemoryLedger(policy: .init(epoch: 1, capBytes: 1 << 20, reserveBytes: 0),
            readUsage: { usage.read() })
        usage.setAvailable(0)
        XCTAssertThrowsError(try MiMoV26ManagedMediaReservation(initialBytes: 4096, hostBytes: 1024,
            maximumBytes: 16384, additionalSystemReserveBytes: 1, ledger: ledger)) { assertOrdinary($0) }
        XCTAssertEqual(ledger.snapshot().ownerCount, 0)
        XCTAssertEqual(ledger.snapshot().chargedBytes, 0)
        XCTAssertEqual(ledger.snapshot().materializedBytes, 0)
        usage.setAvailable(1 << 20)
        let accepted = try MiMoV26ManagedMediaReservation(initialBytes: 4096, hostBytes: 1024,
            maximumBytes: 16384, additionalSystemReserveBytes: 1, ledger: ledger)
        try accepted.disposeUnstartedEncodedPromise() // no decoder/native work was issued
        XCTAssertEqual(ledger.snapshot().ownerCount, 0)
        XCTAssertEqual(ledger.snapshot().chargedBytes, 0)
    }

    func testDecodeGrowthCapacityRefusalPreservesOwnerAndChargeThroughHostCompletion() throws {
        let (usage, ledger, reservation) = try fixture()
        usage.setAvailable(0)
        XCTAssertThrowsError(try reservation.reserveDecodeWorkingBytes(8192)) { assertOrdinary($0) }
        XCTAssertEqual(ledger.snapshot().chargedBytes, 4096)
        XCTAssertEqual(ledger.snapshot().ownerCount, 1)
        XCTAssertEqual(ledger.snapshot().materializedBytes, 0)
        usage.setAvailable(1 << 20)
        try reservation.reserveDecodeWorkingBytes(8192)
        XCTAssertEqual(ledger.snapshot().chargedBytes, 8192)
        reservation.abortBeforeNativeAdoption()
        XCTAssertEqual(ledger.snapshot().chargedBytes, 8192, "abort alone is not host completion")
        try reservation.completeHostOwnership() // metadata-only fixture issued no decoder/native work
        XCTAssertEqual(ledger.snapshot().chargedBytes, 0)
        XCTAssertEqual(ledger.snapshot().ownerCount, 0)
    }

    func testNativeAdoptionCapacityRefusalDoesNotPublishPlanOrLosePriorCharge() throws {
        let (usage, ledger, reservation) = try fixture(), value = plan()
        usage.setAvailable(0)
        XCTAssertThrowsError(try reservation.adoptNativePlan(value, bytes: 8192)) { assertOrdinary($0) }
        XCTAssertEqual(ledger.snapshot().chargedBytes, 4096)
        XCTAssertThrowsError(try reservation.validate(plan: value)) {
            XCTAssertEqual($0 as? MiMoV26MultimodalError, .incompatiblePlan)
        }
        usage.setAvailable(1 << 20)
        try reservation.adoptNativePlan(value, bytes: 8192)
        try reservation.validate(plan: value)
        XCTAssertEqual(ledger.snapshot().chargedBytes, 9216)
        // No native arrays exist in this host fixture; exercise only the two
        // independent phase-completion arithmetic transitions.
        try reservation.retireAfterNativeCompletion()
        XCTAssertEqual(ledger.snapshot().chargedBytes, 1024)
        try reservation.completeHostOwnership()
        XCTAssertEqual(ledger.snapshot().chargedBytes, 0)
        XCTAssertEqual(ledger.snapshot().materializedBytes, 0)
    }

    func testUnknownLedgerAndNativeErrorsAreNotNormalizedByOutwardMapping() {
        for refusal in [ProcessMemoryLedger.Refusal.unknownOwner, .ownerClosing, .staleRevision,
                        .invalidCoverage, .arithmeticOverflow] {
            XCTAssertEqual(MiMoV26EncodedMediaIngress.outwardFailure(refusal) as? ProcessMemoryLedger.Refusal, refusal)
        }
        XCTAssertEqual(MiMoV26EncodedMediaIngress.outwardFailure(MiMoV26MultimodalError.drainFailed)
            as? MiMoV26MultimodalError, .drainFailed)
    }

    func testBothGrowthPhasesMapRealStalePolicyWithoutPublishingNewCharge() throws {
        for adopting in [false, true] {
            let (usage, ledger, reservation) = try fixture(), value = plan()
            // Existing prepareUsage runs after the caller snapshots the epoch
            // and before replaceCharge takes its lock. No timing race or new
            // production hook: this causes the real stalePolicy refusal.
            usage.armPreparation {
                _ = ledger.updatePolicy(.init(epoch: 2, capBytes: 1 << 20, reserveBytes: 0))
            }
            if adopting {
                XCTAssertThrowsError(try reservation.adoptNativePlan(value, bytes: 8192)) { assertOrdinary($0) }
                XCTAssertThrowsError(try reservation.validate(plan: value)) {
                    XCTAssertEqual($0 as? MiMoV26MultimodalError, .incompatiblePlan)
                }
            } else {
                XCTAssertThrowsError(try reservation.reserveDecodeWorkingBytes(8192)) { assertOrdinary($0) }
            }
            XCTAssertEqual(ledger.snapshot().chargedBytes, 4096)
            XCTAssertEqual(ledger.snapshot().materializedBytes, 0)
            reservation.abortBeforeNativeAdoption()
            try reservation.completeHostOwnership() // no decoder/native work in this fixture
            XCTAssertEqual(ledger.snapshot().ownerCount, 0)
        }
    }
}
