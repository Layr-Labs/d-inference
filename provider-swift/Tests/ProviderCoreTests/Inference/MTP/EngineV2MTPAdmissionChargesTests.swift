import XCTest
@testable import MLXLMCommon
@testable import ProviderCore

final class EngineV2MTPAdmissionChargesTests: XCTestCase {
    private var bounded: CBv2MTPAdmissionResolution {
        .bounded(.init(limits: .init(maximumPrefillTokens: 512, maximumDraftTokens: 3),
            residentBytes: 100, workingBytes: 200, hostBytes: 20, fixedBytesPerRequest: 320))
    }

    func testLegacyResolutionPreservesEveryScalarExactly() throws {
        let actual = try EngineV2MTPAdmissionCharges.resolve(
            resolution: nil, legacyMTPBytesPerToken: 20, kvBytesPerToken: 120,
            auxiliaryBytesPerToken: 20, auxiliaryTokenGranularity: 256,
            auxiliaryTokenAllocationPadding: 7, fixedRequestBytes: 80)
        XCTAssertEqual(actual, .init(kvBytesPerToken: 120, auxiliaryBytesPerToken: 20,
            auxiliaryTokenGranularity: 256, auxiliaryTokenAllocationPadding: 7, fixedRequestBytes: 80))
    }

    func testBoundedAssistantRemovesOnlyItsVariableChargeAndDoesNotDoubleFixed() throws {
        let actual = try EngineV2MTPAdmissionCharges.resolve(
            resolution: bounded, legacyMTPBytesPerToken: 20, kvBytesPerToken: 120,
            auxiliaryBytesPerToken: 20, auxiliaryTokenGranularity: 256,
            auxiliaryTokenAllocationPadding: 7, fixedRequestBytes: 420)
        XCTAssertEqual(actual, .init(kvBytesPerToken: 100, auxiliaryBytesPerToken: 0,
            auxiliaryTokenGranularity: 1, auxiliaryTokenAllocationPadding: 0, fixedRequestBytes: 420))
        for context in [1, 128, 1024, 262144, 1048576] {
            XCTAssertEqual(actual.kvBytesPerToken * context + actual.fixedRequestBytes,
                           100 * context + 420)
        }
    }

    func testIndependentCallerAuxiliaryStateRetainsItsRounding() throws {
        let actual = try EngineV2MTPAdmissionCharges.resolve(
            resolution: bounded, legacyMTPBytesPerToken: 20, kvBytesPerToken: 127,
            auxiliaryBytesPerToken: 27, auxiliaryTokenGranularity: 16,
            auxiliaryTokenAllocationPadding: 3, fixedRequestBytes: 421)
        XCTAssertEqual(actual, .init(kvBytesPerToken: 107, auxiliaryBytesPerToken: 7,
            auxiliaryTokenGranularity: 16, auxiliaryTokenAllocationPadding: 3, fixedRequestBytes: 421))
    }

    func testUnavailableEngineResolutionRefusesPublication() {
        XCTAssertThrowsError(try EngineV2MTPAdmissionCharges.resolve(
            resolution: .unavailable(.allocatorPolicyUnavailable), legacyMTPBytesPerToken: 20,
            kvBytesPerToken: 120, auxiliaryBytesPerToken: 20,
            auxiliaryTokenGranularity: 1, auxiliaryTokenAllocationPadding: 0, fixedRequestBytes: Int.max)) {
            XCTAssertEqual($0 as? CBv2MTPAdmissionRefusal, .allocatorPolicyUnavailable)
        }
    }

    func testInconsistentOrOverflowSentinelChargesCannotUnderReserve() {
        for (legacy, total, auxiliary, granularity, padding, fixed) in [
            (-1, 120, 20, 1, 0, 420), (21, 120, 20, 1, 0, 420),
            (20, 19, 20, 1, 0, 420), (20, 120, 20, 0, 0, 420),
            (20, 120, 20, 1, -1, 420), (20, 120, 20, 1, 0, 319),
            (20, 120, 20, 1, 0, Int.max)
        ] {
            XCTAssertThrowsError(try EngineV2MTPAdmissionCharges.resolve(
                resolution: bounded, legacyMTPBytesPerToken: legacy, kvBytesPerToken: total,
                auxiliaryBytesPerToken: auxiliary, auxiliaryTokenGranularity: granularity,
                auxiliaryTokenAllocationPadding: padding, fixedRequestBytes: fixed))
        }
    }
}
