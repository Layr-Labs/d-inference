import Foundation
import Testing

@testable import ProviderBenchmark

/// Opt-in real-weights evaluation of the Qwen partial-prefill (FCFS) policy.
///
/// This is a measurement harness, not a default correctness test: it loads the
/// operator-selected Qwen checkpoint, runs the cap-0 vs cap-1 decision matrix,
/// and prints the evidence report JSON. Real weights are intentionally opt-in;
/// a skipped live suite is not evidence — evaluator math, identity binding,
/// and path privacy remain normal unit tests in
/// `SchedulerPrefillDecisionBenchmarkTests.swift`.
///
/// Run with:
///   DARKBLOOM_QWEN_FCFS_LIVE=1 \
///   DARKBLOOM_QWEN_FCFS_MODEL_PATH=/path/to/snapshot \
///   DARKBLOOM_QWEN_FCFS_MODEL_ID=EigenLabs/Qwen3.6-35B \
///   DARKBLOOM_QWEN_FCFS_EXPECTED_MODEL_HASH=<64-hex aggregate sha256> \
///   DARKBLOOM_QWEN_FCFS_SOURCE_SHA=<git sha> \
///   swift test --filter SchedulerPrefillDecisionLiveTests
@Suite("Qwen partial-prefill live evaluation", .serialized)
struct SchedulerPrefillDecisionLiveTests {
    @Test(
        "real Qwen compares cap zero and one against explicit criteria",
        .enabled(
            if: SchedulerPrefillDecisionCLI.liveEnabled(),
            """
            set DARKBLOOM_QWEN_FCFS_LIVE=1 plus model path, model ID, \
            expected model hash, and source SHA to run the local harness
            """)
    )
    func realQwenDecisionMatrix() async throws {
        let options = try SchedulerPrefillDecisionCLI.liveOptions()
        _ = try #require(
            LiveInferenceFixtures.ensureMetallibColocated(),
            "build/fetch mlx.metallib before running the live harness")
        let report = try await SchedulerPrefillBenchmark.liveQwenPolicyEvaluation(
            modelID: options.modelID,
            modelDirectory: options.modelDirectory,
            expectedSnapshotAggregateSHA256: options.expectedModelHash,
            sourceSHA: options.sourceSHA,
            iterations: options.iterations,
            kvBackend: options.kvBackend)

        #expect(report.mode == .liveModel)
        #expect(report.evidenceClass == .unsignedLocalHarness)
        #expect(report.results.count == 10 * options.iterations)
        #expect(report.modelIdentity?.snapshotAggregateSHA256
            == options.expectedModelHash)
        #expect(report.evaluation.outcome == .pass)
        #expect(!report.evaluation.releaseCandidateCertified)
        #expect(report.results.allSatisfy {
            !$0.rows.isEmpty && $0.aggregatePromptTokensPerSecond > 0
        })
        #expect(report.results.allSatisfy {
            $0.packedPrefill.modelAndCacheSupported == true
        })

        let json = try report.jsonString()
        #expect(!json.contains(options.modelDirectory.path))
        try SchedulerPrefillDecisionCLI.writeOutputIfRequested(Data(json.utf8))
        print(json)
    }
}
