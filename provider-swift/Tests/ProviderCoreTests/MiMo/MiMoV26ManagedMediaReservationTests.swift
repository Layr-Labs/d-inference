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
}
