import CryptoKit
import DarkbloomClusterBootstrap
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
import Foundation
import MLX
import XCTest
@testable import DarkbloomClusterRuntime

final class ProtectedExperimentTests: XCTestCase {
    func testDescriptionPreservesActualOrdinaryCapability() throws {
        let (config, manifest) = try ProtectedExperimentFixture.metadata()
        let bytes = try QwenResidentProtectedExperiment.describe(configuration: config, manifest: manifest,
            runtimeBinarySHA256: ProtectedExperimentFixture.runtimeHash)
        XCTAssertEqual(bytes.last, 10); XCTAssertLessThan(bytes.count, 32 * 1024)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let raw = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(object["ordinaryCapabilityBase64"] as? String)))
        let ordinary = try QwenResidentCapabilityMetadata.describe(configuration: config, manifest: manifest,
            runtimeBinarySHA256: ProtectedExperimentFixture.runtimeHash)
        XCTAssertEqual(raw, try ClusterRuntimeCapabilityCodec.encode(ordinary))
        XCTAssertEqual(object["capabilitySHA256"] as? String, sha256(raw))
        XCTAssertEqual(object["profileFingerprint"] as? String, ordinary.profileFingerprint)
        XCTAssertEqual(object["servingEnabled"] as? Bool, false)
        XCTAssertEqual(object["rdmaMeasured"] as? Bool, false)
        XCTAssertEqual(object["staticProfile"] as? String, QwenResidentProtectedExperiment.identifier)
        let policy = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(object["resourcePolicyBase64"] as? String)))
        XCTAssertEqual(policy, try QwenResidentProtectedExperiment.resourcePolicyBytes())
        XCTAssertEqual(object["resourcePolicySHA256"] as? String, sha256(policy))
        XCTAssertThrowsError(try QwenResidentProtectedExperiment.describe(configuration: config + Data([32]),
            manifest: manifest, runtimeBinarySHA256: ProtectedExperimentFixture.runtimeHash))
    }

    func testFullObservedPhysicalPeakIsNotReducedOrHalved() throws {
        XCTAssertEqual(QwenResidentProtectedExperiment.observedPhysicalIncrement, 71_532_640)
        XCTAssertEqual(QwenResidentProtectedExperiment.meshBackingBytes, 12_533_760)
        XCTAssertEqual(QwenResidentProtectedExperiment.hostAllowanceBytes, 152_748_288)
        XCTAssertEqual(QwenResidentProtectedExperiment.nativeAllowanceBytes, 33_554_432)
        XCTAssertEqual(QwenResidentProtectedExperiment.reservedBytes, 186_302_720)
        XCTAssertGreaterThan(QwenResidentProtectedExperiment.hostAllowanceBytes,
            QwenResidentProtectedExperiment.observedPhysicalIncrement + QwenResidentProtectedExperiment.meshBackingBytes)
    }

    func testClosedWorkloadRefusesEveryDimensionAndStopPolicyChange() throws {
        try QwenResidentProtectedExperiment.requireWorkload(promptCount: 32, chunkSize: 16, outputCount: 2, stopTokenIDs: [])
        for value in [0, 1, 31, 33, 8192] {
            XCTAssertThrowsError(try QwenResidentProtectedExperiment.requireWorkload(promptCount: value,
                chunkSize: 16, outputCount: 2, stopTokenIDs: []))
        }
        for value in [0, 1, 15, 17, 512] {
            XCTAssertThrowsError(try QwenResidentProtectedExperiment.requireWorkload(promptCount: 32,
                chunkSize: value, outputCount: 2, stopTokenIDs: []))
        }
        for value in [0, 1, 3, 128] {
            XCTAssertThrowsError(try QwenResidentProtectedExperiment.requireWorkload(promptCount: 32,
                chunkSize: 16, outputCount: value, stopTokenIDs: []))
        }
        XCTAssertThrowsError(try QwenResidentProtectedExperiment.requireWorkload(promptCount: 32,
            chunkSize: 16, outputCount: 2, stopTokenIDs: [42]))
    }

    func testOnlyActualShortWireArrayGeometriesFit() throws {
        let accepted: [([Int], DType)] = [([1], .uint32), ([64], .int32), ([1], .uint8),
                ([16_384], .uint8), ([1, 16, 4096], .bfloat16), ([1, 1, 4096], .bfloat16)]
        for value in accepted {
            try QwenProtectedArrayGeometry.require(shape: value.0, dtype: value.1)
        }
        let refused: [([Int], DType)] = [([], .uint8), ([0], .uint8), ([16_385], .uint8), ([1], .int32),
                ([1, 16, 4096], .float32), ([1, 16, 5120], .bfloat16), ([1, 512, 4096], .bfloat16),
                ([2, 16, 4096], .bfloat16), ([1, 16, 4095], .bfloat16)]
        for value in refused {
            XCTAssertThrowsError(try QwenProtectedArrayGeometry.require(shape: value.0, dtype: value.1))
        }
    }

    func testBothRanksUseActualMetadataAndSocketIdentity() throws {
        for rank in 0...1 {
            let a = try ProtectedExperimentFixture.admission(rank: rank), s = try ProtectedExperimentFixture.start(a)
            try ProtectedExperimentFixture.require(s, a)
            XCTAssertThrowsError(try ProtectedExperimentFixture.require(s, a,
                identity: .init(membershipEpoch: UUID(), rank: rank)))
            XCTAssertThrowsError(try ProtectedExperimentFixture.require(s, a,
                identity: .init(membershipEpoch: s.common.epoch, rank: 1 - rank)))
        }
    }

    func testPlanArtifactNativeCapabilityResourceAndProfileSubstitutionRefuse() throws {
        let a = try ProtectedExperimentFixture.admission()
        for field in ["plan", "artifact", "native", "capability", "resources", "profile"] {
            let s = try ProtectedExperimentFixture.start(a, overrides: [field: Data(repeating: 7, count: 32)])
            XCTAssertThrowsError(try ProtectedExperimentFixture.require(s, a))
        }
    }

    func testScheduleCutCacheDeadlineAndRecordLimitSubstitutionRefuse() throws {
        for a in [try ProtectedExperimentFixture.admission(cut: 12),
                  try ProtectedExperimentFixture.admission(schedule: .oneChunkLookahead),
                  try ProtectedExperimentFixture.admission(allocator: .unchanged)] {
            XCTAssertThrowsError(try ProtectedExperimentFixture.require(ProtectedExperimentFixture.start(a), a))
        }
        let a = try ProtectedExperimentFixture.admission(), s = try ProtectedExperimentFixture.start(a)
        XCTAssertThrowsError(try ProtectedExperimentFixture.require(s, a, deadline: 0))
        XCTAssertThrowsError(try ProtectedExperimentFixture.require(s, a, deadline: 1_000_001))
        XCTAssertThrowsError(try ProtectedExperimentFixture.require(ProtectedExperimentFixture.start(a,
            schedule: .oneChunkLookahead), a))
        for limits in [try ClusterRecordLimits(maximumPlaintextBytes: 131_071,
                maximumRecordsPerDirection: 1024, maximumCumulativePlaintextBytesPerDirection: 16_777_216),
            try ClusterRecordLimits(maximumPlaintextBytes: 131_072,
                maximumRecordsPerDirection: 1025, maximumCumulativePlaintextBytesPerDirection: 16_777_216),
            try ClusterRecordLimits(maximumPlaintextBytes: 131_072,
                maximumRecordsPerDirection: 1024, maximumCumulativePlaintextBytesPerDirection: 16_777_217)] {
            XCTAssertThrowsError(try ProtectedExperimentFixture.require(ProtectedExperimentFixture.start(a, limits: limits), a))
        }
        XCTAssertThrowsError(try ProtectedExperimentFixture.require(ProtectedExperimentFixture.start(a, frame: 131_113), a))
    }

    func testRequestCreditContainsBothDirectionsAndRetirementAtOriginalQuota() throws {
        let setup = try QwenProtectedRecordBudget.setup(), request = try QwenProtectedRecordBudget.request()
        XCTAssertEqual(setup.records, 2); XCTAssertEqual(setup.plaintextBytes, 512)
        XCTAssertEqual(request.records, 29); XCTAssertEqual(request.plaintextBytes, 461_852)
        XCTAssertEqual(request.nativeTransfers, request.records)
        XCTAssertEqual(request.sealedBytes, request.plaintextBytes + request.records * 40)
        let total = try ClusterRecordTransferEnvelope(entries: [(.exact(256), 2),
            (.exact(131_072), 3 * 16), (.exact(16_384), 3 * 16), (.exact(4096), 4 * 16),
            (.exact(4), 7 * 16), (.exact(256), 12 * 16)], maximumTransportFrameBytes: 131_112)
        XCTAssertEqual(total.records, setup.records + 16 * request.records)
        XCTAssertEqual(total.plaintextBytes, setup.plaintextBytes + 16 * request.plaintextBytes)
        try total.requireRemaining(usedRecords: 0, usedPlaintextBytes: 0, limits: QwenResidentProtectedExperiment.limits())
    }

    func testActualCodecCannotSpendThirdSetupRecordWithoutReservation() throws {
        let io = ProtectedBudgetSink(), codec = try io.transport(), budget = try QwenProtectedRecordBudget()
        for _ in 0..<2 {
            try budget.requireCredit(status: codec.status, sending: true, plaintextBytes: 256)
            try codec.send(Data(repeating: 1, count: 256), expecting: io.expectation(256), check: {})
        }
        XCTAssertEqual(io.frames.count, 2)
        XCTAssertThrowsError(try budget.requireCredit(status: codec.status, sending: true, plaintextBytes: 1))
        XCTAssertThrowsError(try budget.reserveRequest(status: codec.status))
        XCTAssertEqual(codec.status.codec.sealedRecords, 2)
    }

    func testBudgetRejectsActualCounterDriftAndInvalidation() throws {
        let io = ProtectedBudgetSink(), codec = try io.transport(), budget = try QwenProtectedRecordBudget()
        for _ in 0..<3 { try codec.send(Data([1]), expecting: io.expectation(1), check: {}) }
        XCTAssertThrowsError(try budget.reserveRequest(status: codec.status))
        let fresh = try QwenProtectedRecordBudget(); codec.invalidate()
        XCTAssertThrowsError(try fresh.reserveRequest(status: codec.status))
    }

    func testConservativeReservationsNeverRefundAndExhaust() throws {
        let io = ProtectedBudgetSink(), codec = try io.transport(), budget = try QwenProtectedRecordBudget()
        for _ in 0..<16 { try budget.reserveRequest(status: codec.status) }
        // Metadata-only reservation does not consume/reset the actual codec.
        XCTAssertEqual(codec.status.codec.sealedRecords, 0)
        var refused = false
        for _ in 0..<32 {
            do { try budget.reserveRequest(status: codec.status) } catch { refused = true; break }
        }
        XCTAssertTrue(refused)
        XCTAssertThrowsError(try budget.reserveRequest(status: codec.status))
    }

    func testUnqualifiedPolicyRefusesBeforeAnyNativeGroup() throws {
        let configuration = try CollectiveProtectionConfiguration(sessionKey: .init(data: Data(repeating: 1, count: 32)),
            binding: .init(epoch: UUID(), planSHA256: Data(repeating: 2, count: 32),
                membershipTranscriptSHA256: Data(repeating: 3, count: 32)),
            limits: QwenResidentProtectedExperiment.limits(), maximumFrameBytes: 131_112, resourcePolicy: .unqualified)
        XCTAssertThrowsError(try Collective.protected(transport: .jaccl, bootstrap: nil, configuration: configuration))
    }
}
