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
}
