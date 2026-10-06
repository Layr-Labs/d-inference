import Foundation
@testable import MLXVLM
@testable import ProviderCore
import XCTest

/// Real process-ledger arithmetic with controlled usage and request metadata.
/// These do not authenticate/materialize a payload or prove native retirement.
final class MiMoV26AudioSidecarReservationTests: XCTestCase {
    private func request() -> MiMoV26AudioSidecarLoadRequest {
        let object = MiMoV26FilesystemObjectState(device: "test", inode: "test", bytes: 1_872_618_384,
            modifiedSeconds: 0, modifiedNanoseconds: 0, changedSeconds: 0, changedNanoseconds: 0)
        return .init(sessionID: UUID(), canonicalRoot: "/synthetic-metadata-only",
            mainConfigurationSHA256: String(repeating: "0", count: 64),
            configurationSHA256: String(repeating: "1", count: 64), headerSHA256: String(repeating: "2", count: 64),
            payloadSHA256: MiMoV26AudioTokenizerWeights.selectedPayloadSHA256,
            configurationObject: object, payloadObject: object, fileBytes: 1_872_618_384,
            headerBytes: 93_048, inputStoredBytes: 634_204_160, unusedStoredBytes: 1_238_321_176,
            largestInputBytes: 8_388_608, inputTensorCount: 389, unusedTensorCount: 439,
            requiredLoadBytes: 3_879_023_504)
    }

    private func ledger(cap: UInt64 = 16 << 30, available: UInt64 = 32 << 30) -> ProcessMemoryLedger {
        .init(policy: .init(epoch: 1, capBytes: cap, reserveBytes: 1 << 30),
              readUsage: { .init(activeBytes: 0, cacheBytes: 0, systemAvailableBytes: available) })
    }

    func testSeparateChargeLeavesExistingOwnerAndCoverageUnchanged() throws {
        let budget = ledger(), original = budget.createOwner()
        let prior = try budget.replaceCharge(owner: original.owner, expectedRevision: original.revision,
            expectedPolicyEpoch: 1, chargedBytes: 3 << 30)
        let value = request()
        let reservation = try MiMoV26AudioSidecarReservation(request: value, maximumBytes: 4 << 30,
            additionalSystemReserveBytes: 2 << 30, ledger: budget)
        try reservation.validateActive()
        XCTAssertEqual(budget.snapshot().chargedBytes, prior.chargedBytes + value.requiredLoadBytes)
        XCTAssertEqual(budget.state(for: prior.owner), prior)
        XCTAssertEqual(reservation.materializedCoverageForTesting, 0)
        XCTAssertEqual(budget.snapshot().materializedBytes, 0)
        // Metadata-only fixture created no native work/aliases.
        try reservation.retireAfterNativeAliasesReleased()
        try reservation.retireAfterNativeAliasesReleased() // Exact completed owner is idempotent.
        XCTAssertEqual(budget.state(for: prior.owner), prior)
        XCTAssertEqual(budget.snapshot().chargedBytes, prior.chargedBytes)
    }

    func testMaximumAndSystemReserveCannotBeBypassed() throws {
        let value = request(), budget = ledger(available: 1 << 30)
        XCTAssertThrowsError(try MiMoV26AudioSidecarReservation(request: value, maximumBytes: 1,
            additionalSystemReserveBytes: 2 << 30, ledger: budget))
        XCTAssertThrowsError(try MiMoV26AudioSidecarReservation(request: value, maximumBytes: 4 << 30,
            additionalSystemReserveBytes: 0, ledger: budget))
        XCTAssertThrowsError(try MiMoV26AudioSidecarReservation(request: value, maximumBytes: 4 << 30,
            additionalSystemReserveBytes: 2 << 30, ledger: budget))
        XCTAssertEqual(budget.snapshot().ownerCount, 0)
        XCTAssertEqual(budget.snapshot().chargedBytes, 0)
    }

    func testRevokeDoesNotRefundAndNativeFailureCannotBeRehabilitated() throws {
        let budget = ledger(), value = request()
        let reservation = try MiMoV26AudioSidecarReservation(request: value, maximumBytes: 4 << 30,
            additionalSystemReserveBytes: 2 << 30, ledger: budget)
        reservation.revoke()
        XCTAssertThrowsError(try reservation.validateActive())
        XCTAssertEqual(budget.snapshot().chargedBytes, value.requiredLoadBytes)
        reservation.markRetainedFault()
        XCTAssertThrowsError(try reservation.retireAfterNativeAliasesReleased())
        XCTAssertEqual(reservation.chargedBytesForTesting, value.requiredLoadBytes)
        XCTAssertEqual(reservation.materializedCoverageForTesting, 0)
    }
}
