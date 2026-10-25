import DarkbloomClusterProtocol
import Foundation
import XCTest
@testable import DarkbloomClusterWorker

/// Actual startup parser; no model, network or GPU is constructed.
final class QwenTensorAssistantStartupTests: XCTestCase {
    private var arguments: [String] {
        ["--model-dir", "/invented/model", "--rank", "0", "--stage-cut", "16",
         "--membership-epoch", "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", "--model-id", "registered_qwen38_27b",
         "--artifact-sha256", String(repeating: "a", count: 64), "--configuration-sha256", String(repeating: "b", count: 64),
         "--peer0-id", "one", "--peer0-build-sha256", String(repeating: "c", count: 64),
         "--peer1-id", "two", "--peer1-build-sha256", String(repeating: "d", count: 64),
         "--deadline-uptime-nanoseconds", "120000000100", "--startup-deadline-uptime-nanoseconds", "120000000100",
         "--generation-mode", ClusterGenerationMode.tensorParallel.rawValue,
         "--data-plane", ClusterWorkerDataPlaneTrust.argument, "--mtp-depth", "2",
         ClusterQwenTensorAssistantPolicy.inventoryArgument, String(repeating: "e", count: 64)]
    }
    private func removing(_ key: String, from values: [String]) -> [String] {
        var result = values
        if let i = result.firstIndex(of: key) { result.removeSubrange(i...i+1) }
        return result
    }
    func testBothRanksParseIdenticalPinnedPolicyAndKeepLegacyDiagnosticDepth() throws {
        for rank in [0, 1] {
            var args = arguments; args[3] = String(rank)
            let config = try WorkerConfiguration(arguments: args, now: 100)
            XCTAssertEqual(config.tensorAssistantPolicy, try .init(depth: 2, inventorySHA256: String(repeating: "e", count: 64)))
            XCTAssertEqual(config.speculativeTerms?.depth, 2)
            XCTAssertEqual(config.load.rank, rank)
            let legacy = try WorkerConfiguration(arguments: removing(ClusterQwenTensorAssistantPolicy.inventoryArgument, from: args), now: 100)
            XCTAssertNil(legacy.tensorAssistantPolicy)
            XCTAssertEqual(legacy.speculativeTerms?.depth, 2)
        }
    }
    func testPolicyCannotLoseDepthKeyedStartupSerialOrNativeScope() throws {
        for key in ["--mtp-depth", "--data-plane", "--startup-deadline-uptime-nanoseconds", "--generation-mode"] {
            XCTAssertThrowsError(try WorkerConfiguration(arguments: removing(key, from: arguments), now: 100), key)
        }
        for suffix in [["--evidence-directory", "/invented/evidence"], ["--prefill-schedule", "one_chunk_lookahead_v1"],
                       [ClusterQwenTensorAssistantPolicy.inventoryArgument, String(repeating: "e", count: 64)]] {
            XCTAssertThrowsError(try WorkerConfiguration(arguments: arguments + suffix, now: 100))
        }
        for hash in ["short", String(repeating: "A", count: 64), String(repeating: "g", count: 64)] {
            var args = arguments; args[args.count - 1] = hash
            XCTAssertThrowsError(try WorkerConfiguration(arguments: args, now: 100))
        }
        // The 9B's artifact ships the same dense inline head; a routed-expert
        // row's head is an expert layer the tensor owner does not load.
        var nine = arguments; nine[nine.firstIndex(of: "--model-id")! + 1] = "registered_qwen35_9b"
        XCTAssertEqual(try WorkerConfiguration(arguments: nine, now: 100).tensorAssistantPolicy?.depth, 2)
        var foreign = arguments; foreign[foreign.firstIndex(of: "--model-id")! + 1] = "registered_qwen35_35b_a3b"
        XCTAssertThrowsError(try WorkerConfiguration(arguments: foreign, now: 100))
        var pipeline = arguments; pipeline[pipeline.firstIndex(of: "--generation-mode")! + 1] = ClusterGenerationMode.pipelineMTP.rawValue
        XCTAssertThrowsError(try WorkerConfiguration(arguments: pipeline, now: 100))
    }

    func testBothRanksParseExplicitCohortAndRejectUnpinnedOrUnknownVerification() throws {
        let suffix = [ClusterQwenTensorAssistantPolicy.verificationArgument,
            ClusterQwenTensorAssistantPolicy.Verification.admittedCohort.rawValue]
        for rank in [0, 1] {
            var args = arguments + suffix; args[3] = String(rank)
            let config = try WorkerConfiguration(arguments: args, now: 100)
            XCTAssertEqual(config.tensorAssistantPolicy?.verification, .admittedCohort)
            XCTAssertEqual(try config.tensorAssistantPolicy?.maximumSpeculativeWidth(capacity: 4), 4)
            XCTAssertThrowsError(try WorkerConfiguration(arguments:
                removing(ClusterQwenTensorAssistantPolicy.inventoryArgument, from: args), now: 100))
            XCTAssertThrowsError(try WorkerConfiguration(arguments: removing("--mtp-depth", from: args), now: 100))
            XCTAssertThrowsError(try WorkerConfiguration(arguments: args + suffix, now: 100))
        }
        for value in ["", "unknown", "4", "true"] {
            XCTAssertThrowsError(try WorkerConfiguration(arguments:
                arguments + [ClusterQwenTensorAssistantPolicy.verificationArgument, value], now: 100))
        }
    }
}
