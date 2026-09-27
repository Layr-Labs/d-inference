import Foundation
import Testing

@testable import ProviderBenchmark
@testable import ProviderCore

@Suite("Gemma 4 MTP safe verifier performance", .serialized)
struct GemmaMTPSafePerformanceLiveTests {
    @Test(
        "safe automatic verifier performance",
        .enabled(
            if: MTPProductionLiveFixtures.enabled
                && ProcessInfo.processInfo.environment["DARKBLOOM_MTP_SAFE_PERF_DIAGNOSTIC"] == "1",
            Comment(rawValue: "requires the supervised MTP safe performance environment")))
    func safeAutomaticPerformance() async throws {
        let bundle = try await MTPProductionLiveFixtures.loadBundle()
        let report = try await MTPBenchmarkRunner.run(
            target: bundle.targetFacts,
            assistant: bundle.assistantFacts,
            hardware: try MTPBenchmarkModelFacts.hardware(),
            configuration: MTPBenchmarkConfiguration(
                prompts: try MTPProductionLiveFixtures.prompts(bundle: bundle),
                batchSizes: [1, 2, 4, 8],
                modes: [.targetOnly, try .fixed(verificationWidth: 2)],
                maxTokensPerRow: 32,
                purpose: .productionPerformance,
                stopPolicy: .production(tokenIDs: bundle.productionStopTokenIDs),
                warmupIterations: 1,
                measurementRepetitions: 3,
                adaptiveDraftingBatchSizes: []),
            sessions: bundle.makeSessionFactory())
        for item in report.cases.sorted(by: {
            ($0.batchSize, $0.mode.label) < ($1.batchSize, $1.mode.label)
        }) {
            let tps = item.medianAggregateDecodeTokensPerSecond ?? 0
            let rectangularRounds = item.metrics.rectangularVerificationRounds ?? 0
            let serialRounds = item.metrics.serialVerificationRounds ?? 0
            print(
                "MTP_SAFE_PERF batch=\(item.batchSize) mode=\(item.mode.label) "
                    + "tps=\(tps) rect=\(rectangularRounds) serial=\(serialRounds)")
        }
    }
}
