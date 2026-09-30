import MLXLMCommon
import XCTest
@testable import ProviderCore

final class MiMoV26RectangularVerifyPolicyTests: XCTestCase {
    func testDefaultAndNoncanonicalValuesStaySerial() {
        for environment in [[:], ["DARKBLOOM_MIMO_RECTANGULAR_VERIFY": "0"],
                            ["DARKBLOOM_MIMO_RECTANGULAR_VERIFY": "true"],
                            ["DARKBLOOM_MIMO_RECTANGULAR_VERIFY": " 1"]] {
            XCTAssertEqual(EngineV2SlotFactory.nativeMiMoVerificationMode(
                wantsMTP: true, environment: environment), .serialTarget)
        }
    }
    func testCandidateFlagCannotActivateDisabledMTP() {
        XCTAssertEqual(EngineV2SlotFactory.nativeMiMoVerificationMode(wantsMTP: false,
            environment: ["DARKBLOOM_MIMO_RECTANGULAR_VERIFY": "1"]), .serialTarget)
    }
    func testExplicitEnabledCandidateSelectsRectangularNotExactLabel() {
        XCTAssertEqual(EngineV2SlotFactory.nativeMiMoVerificationMode(wantsMTP: true,
            environment: ["DARKBLOOM_MIMO_RECTANGULAR_VERIFY": "1"]), .rectangular)
    }
    func testNativeMTPConfigKeepsAdaptiveSerialPlansTargetOnly() {
        for wantsMTP in [true, false] {
            for mode in [CBv2MTPVerificationMode.serialTarget, .rectangular] {
                let config = EngineV2SlotFactory.nativeMiMoMTPConfig(
                    wantsMTP: wantsMTP, verificationMode: mode)
                XCTAssertEqual(config.enabled, wantsMTP)
                XCTAssertEqual(config.maxDraftTokens, 3)
                XCTAssertEqual(config.maxSpeculativeBatch, 1)
                XCTAssertNil(config.fixedDraftTokens, "MTP stays adaptive, not fixed zero")
                XCTAssertEqual(config.verificationMode, mode)
                XCTAssertFalse(config.allowsAdaptiveSerialRounds)
            }
        }
        XCTAssertTrue(CBv2MTPConfig().allowsAdaptiveSerialRounds, "SDK default is unchanged")
    }
}
