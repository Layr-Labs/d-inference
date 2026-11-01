import Foundation
import XCTest
@testable import MLXVLM
@testable import ProviderCore

final class MiMoV26ManagedMediaReservationTests: XCTestCase {
    private final class ControlledUsage: @unchecked Sendable {
        private let lock = NSLock()
        private var available: UInt64 = 1 << 20
        func setAvailable(_ value: UInt64) { lock.withLock { available = value } }
        func read() -> ProcessMemoryLedger.Usage {
            lock.withLock {
                .init(activeBytes: 0, cacheBytes: 0, systemAvailableBytes: available)
            }
        }
    }

    private func metadataPlan() -> MiMoV26MultimodalPlan {
        .init(promptTokens: [1], spans: [],
            maximumOutputTokens: 1, preparationSHA256: "host-test",
            profile: "host-ledger-test", loadedOwnerIdentity: UUID(),
            configurationSHA256: "config", templateSHA256: "template",
            visionGeometryByMediaIndex: [:], audioPlan: nil,
            decodedElements: 0, patchElements: 0, featureElements: 0,
            logicalFeatureBytes: 0, processorIdentity: UUID(), parts: [])
    }

    func testCapacityRefusalDoesNotPoisonOrRefundReservation() throws {
        let usage = ControlledUsage()
        let ledger = ProcessMemoryLedger(
            policy: .init(epoch: 1, capBytes: 1 << 20, reserveBytes: 0),
            readUsage: { usage.read() })
        let plan = metadataPlan()
        let reservation = try MiMoV26ManagedMediaReservation(plan: plan,
            bytes: 4096, maximumBytes: 8192,
            additionalSystemReserveBytes: 1, ledger: ledger, serviceBudget: .init())

        usage.setAvailable(0)
        XCTAssertThrowsError(try reservation.validate(plan: plan)) { error in
            guard let refusal = error as? MiMoV26MultimodalError,
                  case .reservationRejected = refusal else {
                return XCTFail("Expected ordinary admission refusal, got \(error)")
            }
        }
        XCTAssertEqual(ledger.snapshot().chargedBytes, 4096)
        XCTAssertEqual(ledger.snapshot().materializedBytes, 0)
        usage.setAvailable(1 << 20)
        try reservation.validate(plan: plan)
        // Metadata-only fixture issued no native work or aliases.
        try reservation.retireAfterNativeCompletion()
        XCTAssertEqual(ledger.snapshot().chargedBytes, 0)
        XCTAssertEqual(ledger.snapshot().ownerCount, 0)
    }

    func testLaterSDKDrainFailureRetainsSharedRateInvalidationAfterPreparationEnds() throws {
        let usage = ControlledUsage()
        let ledger = ProcessMemoryLedger(
            policy: .init(epoch: 1, capBytes: 1 << 20, reserveBytes: 0),
            readUsage: { usage.read() })
        let service = deadlineReadyServiceBudgetFixture()
        let plan = metadataPlan()
        let reservation = try MiMoV26ManagedMediaReservation(plan: plan,
            bytes: 4096, maximumBytes: 8192, additionalSystemReserveBytes: 1,
            ledger: ledger, serviceBudget: service)
        let preparation = service.beginUnboundedActivity()
        preparation.finish()
        XCTAssertTrue(service.acquire(ownerID: "peer", concurrency: 1,
            work: .init(modelID: "peer", profileID: "peer-profile", promptTokens: 1_000, maxOutputTokens: 1)))
        defer { service.release(ownerID: "peer") }
        let evidence = try XCTUnwrap(service.captureNativeMediaRateEvidence(ownerID: "peer", modelID: "peer"))
        XCTAssertTrue(service.deadlineWork(modelID: "peer", epoch: "peer-epoch").known)

        // Drive the SDK's actual failure callback after preparation has ended.
        // The metadata-only work injects a drain error; no GPU allocation,
        // throughput claim or fabricated successful retirement is involved.
        enum Failure: Error { case injected }
        let work = MiMoV26FailedMediaWork(plan: plan, owner: NSObject(), codec: nil, reservation: reservation)
        XCTAssertThrowsError(try work.drain(generation: .init(), synchronize: { throw Failure.injected }))
        XCTAssertTrue(work.failedDrain)
        XCTAssertFalse(evidence.guardToken.isValid)
        XCTAssertFalse(service.deadlineWork(modelID: "peer", epoch: "peer-epoch").known)
        XCTAssertNil(service.captureNativeMediaRateEvidence(ownerID: "peer", modelID: "peer"))
        XCTAssertEqual(ledger.snapshot().chargedBytes, 4096)
        XCTAssertThrowsError(try reservation.retireAfterNativeCompletion())

        // Repeated failure delivery and another completed activity cannot
        // remove the failed reservation's independent activity ownership.
        reservation.retainAfterFailedDrain(work)
        let later = service.beginUnboundedActivity()
        later.finish()
        XCTAssertFalse(service.deadlineWork(modelID: "peer", epoch: "peer-epoch").known)
        XCTAssertNil(service.captureNativeMediaRateEvidence(ownerID: "peer", modelID: "peer"))
        XCTAssertEqual(ledger.snapshot().chargedBytes, 4096)
        // Break the SDK retention cycle using its genuine captured-stream
        // recovery. The provider's failed reservation still supplies no refund.
        try work.recoverAndReleaseAfterDrain()
        XCTAssertFalse(service.deadlineWork(modelID: "peer", epoch: "peer-epoch").known)
        XCTAssertEqual(ledger.snapshot().chargedBytes, 4096)
    }

    /// A refused media charge requests the shortfall reclaim (retained KV
    /// segments, then MLX's buffer cache) like a refused request reservation,
    /// including when only the extra system reserve refused it.
    func testCapacityRefusalSignalsShortfallReclaim() throws {
        let usage = ControlledUsage()
        usage.setAvailable(10_000)
        let ledger = ProcessMemoryLedger(
            policy: .init(epoch: 1, capBytes: 1 << 20, reserveBytes: 0),
            readUsage: { usage.read() })
        let signals = ShortfallSignals()

        // 8,000 B fits the 10,000 B the ledger has left; the 4,000 B system
        // reserve refuses it, short by 2,000 B.
        XCTAssertThrowsError(try MiMoV26ManagedMediaReservation(initialBytes: 8_000, hostBytes: 0,
            maximumBytes: 1 << 20, additionalSystemReserveBytes: 4_000, ledger: ledger,
            serviceBudget: .init(), onRefusal: { signals.record($0) }))
        XCTAssertEqual(signals.values, [2_000])

        let reservation = try MiMoV26ManagedMediaReservation(initialBytes: 4_000, hostBytes: 4_000,
            maximumBytes: 1 << 20, additionalSystemReserveBytes: 4_000, ledger: ledger,
            serviceBudget: .init(), onRefusal: { signals.record($0) })
        XCTAssertEqual(signals.values, [2_000], "an admitted charge signals nothing")
        // Growing to 9,000 B needs 5,000 B more beside the reserve; 6,000 B remain.
        XCTAssertThrowsError(try reservation.reserveDecodeWorkingBytes(9_000))
        XCTAssertEqual(signals.values, [2_000, 3_000])
        XCTAssertEqual(ledger.snapshot().chargedBytes, 4_000)
    }

    /// When the process cap rather than OS-available RAM binds, the extra
    /// system reserve plays no part in the refusal. Counting it would inflate
    /// the shortfall past a buffer cache whose flush lets the retry fit.
    func testCapBoundRefusalSignalsOnlyTheCapDeficit() throws {
        let usage = ControlledUsage() // 1 MiB available: the cap binds.
        let ledger = ProcessMemoryLedger(
            policy: .init(epoch: 1, capBytes: 6_000, reserveBytes: 0),
            readUsage: { usage.read() })
        let signals = ShortfallSignals()

        // 8,000 B against 6,000 B of cap headroom is short by 2,000 B.
        XCTAssertThrowsError(try MiMoV26ManagedMediaReservation(initialBytes: 8_000, hostBytes: 0,
            maximumBytes: 1 << 20, additionalSystemReserveBytes: 4_000, ledger: ledger,
            serviceBudget: .init(), onRefusal: { signals.record($0) }))
        XCTAssertEqual(signals.values, [2_000])

        let reservation = try MiMoV26ManagedMediaReservation(initialBytes: 4_000, hostBytes: 4_000,
            maximumBytes: 1 << 20, additionalSystemReserveBytes: 4_000, ledger: ledger,
            serviceBudget: .init(), onRefusal: { signals.record($0) })
        // Growing to 9,000 B promises 3,000 B more than the cap leaves.
        XCTAssertThrowsError(try reservation.reserveDecodeWorkingBytes(9_000))
        XCTAssertEqual(signals.values, [2_000, 3_000])

        // A recheck after the cap shrinks to 3,000 B is short by the 1,000 B
        // its unchanged 4,000 B promise now exceeds it by.
        let rechecked = ProcessMemoryLedger(
            policy: .init(epoch: 1, capBytes: 6_000, reserveBytes: 0),
            readUsage: { usage.read() })
        let plan = metadataPlan()
        let planned = try MiMoV26ManagedMediaReservation(plan: plan, bytes: 4_000,
            maximumBytes: 8_192, additionalSystemReserveBytes: 4_000, ledger: rechecked,
            serviceBudget: .init(), onRefusal: { signals.record($0) })
        XCTAssertTrue(rechecked.updatePolicy(.init(epoch: 2, capBytes: 3_000, reserveBytes: 0)))
        XCTAssertThrowsError(try planned.validate(plan: plan))
        XCTAssertEqual(signals.values, [2_000, 3_000, 1_000])
    }

    private final class ShortfallSignals: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [UInt64] = []
        var values: [UInt64] { lock.withLock { recorded } }
        func record(_ shortfall: UInt64) { lock.withLock { recorded.append(shortfall) } }
    }
}
