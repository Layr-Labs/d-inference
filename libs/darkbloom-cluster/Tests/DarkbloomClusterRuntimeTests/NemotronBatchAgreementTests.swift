import XCTest
@testable import DarkbloomClusterRuntime

final class NemotronBatchAgreementTests: XCTestCase {
    func testSingletonAndOtherFamiliesRetainExistingAgreement() throws {
        XCTAssertEqual(try QwenBatchSettings.fromEnvironment([:]), .single)
        XCTAssertTrue(QwenBatchSettings.single.loadAgreementFields(runtimeModelID: "registered_nemotron35_lightning").isEmpty)
        for lanes in 1...8 {
            let settings = QwenBatchSettings(lanes: lanes)
            for id in ["registered_qwen35_9b", "registered_ternary_bonsai_2_27b", "registered_glm5_next", "unknown"] {
                XCTAssertEqual(settings.loadAgreementFields(runtimeModelID: id), settings.loadAgreementFields)
            }
        }
    }

    func testNemotronWidthAndOwnedRowArithmeticAreBoundTogether() {
        let all = (2...8).map { QwenBatchSettings(lanes: $0).loadAgreementFields(runtimeModelID: "registered_nemotron35_lightning") }
        XCTAssertEqual(Set(all).count, 7)
        for (index, fields) in all.enumerated() {
            let base = QwenBatchSettings(lanes: index + 2).loadAgreementFields
            XCTAssertEqual(fields, base + ["nemotron35-batch-v1", "row-m1", "owned-recurrent-rows"])
            XCTAssertNotEqual(fields, base)
        }
    }
}
