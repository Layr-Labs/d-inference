import MLX
import MLXLMCommon
import XCTest
@testable import ProviderCore

/// Drafter on the protocol default, like `MiMoV26MTPAssistant`: no
/// target-prefix acceptance.
private final class NativeMiMoShapedDrafter: CBv2MTPDrafter {
    private final class Capture: CBv2MTPPreparedCapture {}
    func prepare(rows: [CBv2MTPRowCapture]) -> any CBv2MTPPreparedCapture { Capture() }
    func draftStep(tokens: MLXArray, hidden: MLXArray, prepared: any CBv2MTPPreparedCapture)
        -> (tokens: MLXArray, hidden: MLXArray) {
        preconditionFailure("policy fixture must not run draft math")
    }
}

final class MiMoV26RectangularVerifyPolicyTests: XCTestCase {
    func testExactRectangularIsTheDefaultAndAffirmativeValuesKeepIt() {
        for environment in [[:], ["DARKBLOOM_MIMO_RECTANGULAR_VERIFY": "1"],
                            ["DARKBLOOM_MIMO_RECTANGULAR_VERIFY": "true"],
                            ["DARKBLOOM_MIMO_RECTANGULAR_SCALAR_DENSE": "1"]] {
            XCTAssertEqual(EngineV2SlotFactory.nativeMiMoVerificationMode(
                wantsMTP: true, environment: environment), .rectangular)
        }
    }
    func testEitherRollbackSelectsSerialNeverBulkRectangular() {
        for key in ["DARKBLOOM_MIMO_RECTANGULAR_VERIFY", "DARKBLOOM_MIMO_RECTANGULAR_SCALAR_DENSE"] {
            for value in ["0", "false", "no", "off", " OFF "] {
                XCTAssertEqual(EngineV2SlotFactory.nativeMiMoVerificationMode(
                    wantsMTP: true, environment: [key: value]), .serialTarget, "\(key)=\(value)")
            }
        }
    }
    func testVerificationStrategyCannotActivateDisabledMTP() {
        for environment in [[:], ["DARKBLOOM_MIMO_RECTANGULAR_VERIFY": "1"]] {
            XCTAssertEqual(EngineV2SlotFactory.nativeMiMoVerificationMode(
                wantsMTP: false, environment: environment), .serialTarget)
        }
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
    func testNativeMTPConfigInstallsExactWhenTypicalCannotApply() {
        for wantsMTP in [true, false] {
            for mode in [CBv2MTPVerificationMode.serialTarget, .rectangular] {
                var config = EngineV2SlotFactory.nativeMiMoMTPConfig(
                    wantsMTP: wantsMTP, verificationMode: mode)
                var warnings: [String] = []
                EngineV2SlotFactory.installMTPAcceptance(
                    byModel: ["mimo-v2.6": "typical"], into: &config,
                    drafter: wantsMTP ? NativeMiMoShapedDrafter() : nil,
                    modelID: "mimo-v2.6", logInfo: { _ in }, logWarning: { warnings.append($0) })
                XCTAssertEqual(config.acceptance, .exact)
                XCTAssertEqual(warnings.count, 1)
                XCTAssertTrue(warnings.first?.contains("mimo-v2.6") == true)
                XCTAssertTrue(warnings.first?.contains(wantsMTP
                    ? "does not support target-prefix acceptance" : "MTP is off") == true)
            }
        }
        var exact = EngineV2SlotFactory.nativeMiMoMTPConfig(wantsMTP: true, verificationMode: .serialTarget)
        var warnings: [String] = []
        EngineV2SlotFactory.installMTPAcceptance(
            byModel: [:], into: &exact, drafter: NativeMiMoShapedDrafter(), modelID: "mimo-v2.6",
            logInfo: { _ in }, logWarning: { warnings.append($0) })
        XCTAssertEqual(exact.acceptance, .exact)
        XCTAssertTrue(warnings.isEmpty, "the exact default never warns")
    }
}
