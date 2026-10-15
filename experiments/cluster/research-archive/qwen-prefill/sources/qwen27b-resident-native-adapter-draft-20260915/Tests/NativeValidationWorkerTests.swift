import DarkbloomClusterProtocol
import Foundation
import XCTest
@_spi(Benchmark) import DarkbloomClusterRuntime
@testable import DarkbloomClusterWorker

final class NativeValidationWorkerTests: XCTestCase {
    private var arguments: [String] {
        ["--model-dir", "/fabricated/model", "--rank", "0", "--stage-cut", "4",
         "--membership-epoch", "435811c9-e834-4294-8641-8e8975f07849", "--model-id", "registered_qwen38_27b",
         "--artifact-sha256", "bbd0e0adcfe74e095073fefd0b9e116e4311d606ad9989cf81f8175e8ac18463",
         "--configuration-sha256", "4691da94a1b4ef415aad112ec46abebd33f8a41ad07380e486c0526eb945c1ff",
         "--peer0-id", "a", "--peer0-build-sha256", String(repeating: "a", count: 64),
         "--peer1-id", "b", "--peer1-build-sha256", String(repeating: "b", count: 64),
         "--deadline-uptime-nanoseconds", "1000"]
    }
    private func replacing(_ input: [String], _ key: String, _ value: String) -> [String] {
        var result = input; result[result.firstIndex(of: key)! + 1] = value; return result
    }
    func testExplicitSelectionUsesTheSameWorkerConfiguration() throws {
        for rank in [0, 1] { for cut in try QwenResidentNativeValidationModel.qwen38TwentySevenB.supportedCuts {
            let args = replacing(replacing(arguments, "--rank", String(rank)), "--stage-cut", String(cut))
            let value = try WorkerConfiguration(arguments: args, now: 100, nativeValidation: .qwen38TwentySevenB)
            XCTAssertEqual(value.load.identity.modelID, "registered_qwen38_27b")
            XCTAssertEqual(value.load.rank, rank)
            XCTAssertEqual(value.load.stageCut, cut)
            XCTAssertEqual(value.load.prefillSchedule, .serial)
        } }
    }
    func testOrdinaryPathAndCrossedArgumentsStillRefuse() {
        XCTAssertThrowsError(try WorkerConfiguration(arguments: arguments, now: 100))
        for (key, bad) in [("--model-id", "registered_qwen35_9b"), ("--stage-cut", "20"),
                           ("--artifact-sha256", String(repeating: "a", count: 64)),
                           ("--configuration-sha256", String(repeating: "b", count: 64)),
                           ("--deadline-uptime-nanoseconds", "100")] {
            XCTAssertThrowsError(try WorkerConfiguration(arguments: replacing(arguments, key, bad),
                now: 100, nativeValidation: .qwen38TwentySevenB))
        }
        XCTAssertThrowsError(try WorkerConfiguration(arguments: arguments + ["--prefill-schedule", "one_chunk_lookahead_v1"],
            now: 100, nativeValidation: .qwen38TwentySevenB))
        XCTAssertThrowsError(try WorkerConfiguration(arguments: arguments + ["--rank", "1"],
            now: 100, nativeValidation: .qwen38TwentySevenB))
    }
}
