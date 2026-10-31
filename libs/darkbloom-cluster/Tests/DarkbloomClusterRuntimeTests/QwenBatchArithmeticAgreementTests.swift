import XCTest
@testable import DarkbloomClusterRuntime

final class QwenBatchArithmeticAgreementTests: XCTestCase {
    func testSingleLaneRetainsItsExistingAgreementAndDefault() throws {
        XCTAssertEqual(try QwenBatchSettings.fromEnvironment([:]), .single)
        XCTAssertTrue(QwenBatchSettings.single.loadAgreementFields.isEmpty)
    }

    func testMultiLaneRefusesOldArithmeticAndDifferentWidths() {
        for lanes in 2...8 {
            let fields = QwenBatchSettings(lanes: lanes).loadAgreementFields
            XCTAssertNotEqual(fields, ["qwen-batch-v2", "lanes=\(lanes)"])
            XCTAssertEqual(fields, ["qwen-batch-v3", "lanes=\(lanes)", "qwen35-row-m1"])
            XCTAssertEqual(Set((2...8).map { QwenBatchSettings(lanes: $0).loadAgreementFields }).count, 7)
        }
    }
}
