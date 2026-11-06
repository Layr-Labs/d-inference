import DarkbloomClusterProtocol
import DarkbloomClusterRuntime
import Foundation
import XCTest
@testable import DarkbloomClusterWorker

/// The startup parser for Gemma tensor parallel with its pinned assistant (`ClusterGemmaTensorAssistant`); no model,
/// network or GPU is constructed.
final class GemmaTensorAssistantStartupTests: XCTestCase {
    private var cut: String {
        String(ClusterResidentModelCatalog.entry(runtimeModelID: "registered_gemma4_26b_qat_4bit")?.supportedCuts.sorted().first ?? 15)
    }
    private var arguments: [String] {
        ["--model-dir", "/invented/model", "--rank", "0", "--stage-cut", cut,
         "--membership-epoch", "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", "--model-id", "registered_gemma4_26b_qat_4bit",
         "--artifact-sha256", String(repeating: "a", count: 64), "--configuration-sha256", String(repeating: "b", count: 64),
         "--peer0-id", "one", "--peer0-build-sha256", String(repeating: "c", count: 64),
         "--peer1-id", "two", "--peer1-build-sha256", String(repeating: "d", count: 64),
         "--deadline-uptime-nanoseconds", "120000000100",
         "--generation-mode", ClusterGenerationMode.tensorParallel.rawValue,
         "--data-plane", ClusterWorkerDataPlaneTrust.argument, "--mtp-depth", "3",
         ClusterGemmaTensorAssistant.directoryArgument, "/invented/spec-dec/assistant",
         ClusterGemmaTensorAssistant.aggregateArgument, String(repeating: "e", count: 64)]
    }
    private func removing(_ key: String, from values: [String]) -> [String] {
        var result = values
        if let i = result.firstIndex(of: key) { result.removeSubrange(i...i+1) }
        return result
    }
    private func replacing(_ key: String, with value: String, in values: [String]) -> [String] {
        var result = values
        result[result.firstIndex(of: key)! + 1] = value
        return result
    }

    func testBothRanksParseTheAssistantItsAggregateAndDepth() throws {
        for rank in [0, 1] {
            var args = arguments; args[3] = String(rank)
            let config = try WorkerConfiguration(arguments: args, now: 100)
            XCTAssertEqual(config.gemmaAssistant?.directory.path, "/invented/spec-dec/assistant")
            XCTAssertEqual(config.gemmaAssistant?.aggregateSHA256, String(repeating: "e", count: 64))
            XCTAssertEqual(config.speculativeTerms?.depth, 3)
            XCTAssertNil(config.tensorAssistantPolicy)
        }
        // The provider's own launch arguments parse to the same.
        let launched = removing("--mtp-depth", from: removing(ClusterGemmaTensorAssistant.directoryArgument,
            from: removing(ClusterGemmaTensorAssistant.aggregateArgument, from: arguments)))
            + (try ClusterGemmaTensorAssistant.workerArguments(depth: 3, directory: "/invented/spec-dec/assistant",
                                                               aggregateSHA256: String(repeating: "e", count: 64)))
        XCTAssertEqual(try WorkerConfiguration(arguments: launched, now: 100).gemmaAssistant?.aggregateSHA256,
                       String(repeating: "e", count: 64))
        // Without the assistant the row decodes plain, with no depth.
        let plain = try WorkerConfiguration(arguments: removing("--mtp-depth", from: removing(ClusterGemmaTensorAssistant.directoryArgument,
            from: removing(ClusterGemmaTensorAssistant.aggregateArgument, from: arguments))), now: 100)
        XCTAssertNil(plain.gemmaAssistant)
        XCTAssertNil(plain.speculativeTerms)
    }

    func testTheAssistantNeedsItsDepthAggregateKeyedTensorParallelAndANormalizedDirectory() throws {
        for key in ["--mtp-depth", "--data-plane", "--generation-mode", ClusterGemmaTensorAssistant.aggregateArgument,
                    ClusterGemmaTensorAssistant.directoryArgument] {
            XCTAssertThrowsError(try WorkerConfiguration(arguments: removing(key, from: arguments), now: 100), key)
        }
        for directory in ["relative/assistant", "/a/../b", "/a//b"] {
            XCTAssertThrowsError(try WorkerConfiguration(arguments: replacing(ClusterGemmaTensorAssistant.directoryArgument,
                with: directory, in: arguments), now: 100), directory)
        }
        for hash in ["short", String(repeating: "A", count: 64)] {
            XCTAssertThrowsError(try WorkerConfiguration(arguments: replacing(ClusterGemmaTensorAssistant.aggregateArgument,
                with: hash, in: arguments), now: 100))
        }
        XCTAssertThrowsError(try WorkerConfiguration(arguments: replacing("--mtp-depth", with: "5", in: arguments), now: 100))
        XCTAssertThrowsError(try WorkerConfiguration(arguments: replacing("--model-id", with: "registered_gemma4_26b_8bit",
            in: arguments), now: 100))
        XCTAssertThrowsError(try WorkerConfiguration(arguments: replacing("--generation-mode",
            with: ClusterGenerationMode.pipeline.rawValue, in: arguments), now: 100))
    }
}
