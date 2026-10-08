import Foundation
import XCTest
@testable import DarkbloomClusterRuntime

final class ProtectedEvidenceTests: XCTestCase {
    private enum Stop: Error { case cancelled }

    func testExportAddsOnlyNamedHostStorageToOriginalProtectedBudget() throws {
        XCTAssertEqual(QwenProtectedEvidenceBudget.additionalHostBytes, 10 * 1_048_576)
        XCTAssertEqual(QwenResidentProtectedExperiment.reservedBytes, 196_788_480)
        XCTAssertEqual(QwenResidentProtectedExperiment.nativeAllowanceBytes, 33_554_432)
        try QwenProtectedEvidenceBudget.requireAllocation(8 * 1_048_576)
        try QwenProtectedEvidenceBudget.requireAllocation(9 * 1_048_576)
        XCTAssertThrowsError(try QwenProtectedEvidenceBudget.requireAllocation(8 * 1_048_576 - 1))
        XCTAssertThrowsError(try QwenProtectedEvidenceBudget.requireAllocation(9 * 1_048_576 + 1))
    }

    func testFullRowEncodingPreservesEveryFloat32ValueAndBoundsNativeRowMetadata() throws {
        // Fixture-only CPU values. This is an encoding test, never native evidence.
        let pattern: [Float] = [0, -0.0, 1, -1, 0.125, 3.5, -64, 65536]
        let values = (0..<QwenProtectedEvidenceBudget.vocabularySize).map { pattern[$0 % pattern.count] }
        let row = QwenRecordedLogitValues(shape: [1, values.count], dtype: "bfloat16",
            byteCount: values.count * 2, logicalBytesSHA256: String(repeating: "a", count: 64), values: values)
        let writer = try QwenProtectedEvidenceJSON()
        var checks = 0
        try QwenProtectedEvidenceExport.logits(row, into: writer) { checks += 1 }
        XCTAssertEqual(checks, (values.count + 1023) / 1024)
        try writer.publish { data in
            XCTAssertLessThan(data.count, QwenProtectedEvidenceBudget.maximumEncodedBytes)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let actual = try XCTUnwrap(object["values"] as? [NSNumber])
            XCTAssertEqual(actual.count, values.count)
            for (a, b) in zip(actual, values) { XCTAssertEqual(a.floatValue.bitPattern, b.bitPattern) }
            XCTAssertEqual(object["shape"] as? [Int], [1, values.count])
            XCTAssertEqual(object["dtype"] as? String, "bfloat16")
        }
        XCTAssertThrowsError(try writer.publish { _ in XCTFail("Repeated output escaped") })
    }

    func testNonfiniteValuesUnsafeStringsAndFixedBufferOverflowRefuse() throws {
        let writer = try QwenProtectedEvidenceJSON()
        for value in [Float.nan, Float.infinity, -Float.infinity] { XCTAssertThrowsError(try writer.floating(value)) }
        for value in ["quote\"", "escape\\", "line\n", "\0"] { XCTAssertThrowsError(try writer.string(value)) }
        let block = String(repeating: "a", count: 1024)
        for _ in 0..<(QwenProtectedEvidenceBudget.maximumEncodedBytes / 1024) { try writer.raw(block) }
        XCTAssertEqual(writer.count, QwenProtectedEvidenceBudget.maximumEncodedBytes)
        XCTAssertThrowsError(try writer.raw("x"))
    }

    func testCancellationBeforePublicationAndRetainedDataNeverSucceed() throws {
        let values = [Float](repeating: 1, count: QwenProtectedEvidenceBudget.vocabularySize)
        let row = QwenRecordedLogitValues(shape: [1, values.count], dtype: "bfloat16",
            byteCount: values.count * 2, logicalBytesSHA256: String(repeating: "a", count: 64), values: values)
        let interrupted = try QwenProtectedEvidenceJSON()
        XCTAssertThrowsError(try QwenProtectedEvidenceExport.logits(row, into: interrupted) { throw Stop.cancelled })
        let retained = try QwenProtectedEvidenceJSON(); try retained.raw(String(repeating: "x", count: 1024))
        var leaked: Data?
        XCTAssertThrowsError(try retained.publish { leaked = $0 })
        XCTAssertNotNil(leaked); leaked = nil
    }
}
