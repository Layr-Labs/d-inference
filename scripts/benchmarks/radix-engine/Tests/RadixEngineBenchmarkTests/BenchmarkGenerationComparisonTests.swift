import XCTest
@testable import radix_engine

final class BenchmarkGenerationComparisonTests: XCTestCase {
    func testPolicyPreservesStrictDefaultSemantics() {
        XCTAssertTrue(BenchmarkGenerationComparisonPolicy.strict.rejectsTokenDifference(false))
        XCTAssertFalse(BenchmarkGenerationComparisonPolicy.record.rejectsTokenDifference(false))
        XCTAssertFalse(BenchmarkGenerationComparisonPolicy.strict.rejectsTokenDifference(true))
        XCTAssertNil(BenchmarkGenerationComparisonPolicy(rawValue: "ignore"))
    }

    func testDifferenceRetainsIdentityAndCancelledLongerPrefix() throws {
        let donor: [String: Any] = ["id": "same-id", "kind": "first", "scope": "a",
                                  "prompt_token_ids": [1, 2], "token_ids": [3, 4],
                                  "finish": "length", "completion_tokens": 2]
        var cancelled = donor
        cancelled["token_ids"] = [3, 4, 5]
        cancelled["finish"] = "cancelled"
        cancelled["completion_tokens"] = 3
        let records = try BenchmarkGenerationComparison.records(["cancel_donor": donor, "cancelled": cancelled])
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["tokens_equal"] as? Bool, false)
        XCTAssertEqual(records[0]["first_difference_zero_based"] as? Int, 2)
        XCTAssertEqual(records[0]["outcome"] as? String, "FAIL")
        let left = try XCTUnwrap(records[0]["left"] as? [String: Any])
        XCTAssertEqual(left["path"] as? String, "cancel_donor")
        XCTAssertEqual((left["token_ids_sha256"] as? String)?.count, 64)
    }
}
