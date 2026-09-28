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

    func testCapacityRefusalDoesNotPoisonOrRefundReservation() throws {
        let usage = ControlledUsage()
        let ledger = ProcessMemoryLedger(
            policy: .init(epoch: 1, capBytes: 1 << 20, reserveBytes: 0),
            readUsage: { usage.read() })
        let plan = MiMoV26MultimodalPlan(promptTokens: [1], spans: [],
            maximumOutputTokens: 1, preparationSHA256: "host-test",
            profile: "host-ledger-test", loadedOwnerIdentity: UUID(),
            configurationSHA256: "config", templateSHA256: "template",
            visionGeometryByMediaIndex: [:], audioPlan: nil,
            decodedElements: 0, patchElements: 0, featureElements: 0,
            logicalFeatureBytes: 0, processorIdentity: UUID(), parts: [])
        let reservation = try MiMoV26ManagedMediaReservation(plan: plan,
            bytes: 4096, maximumBytes: 8192,
            additionalSystemReserveBytes: 1, ledger: ledger)

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
}
