import MLX
import Testing

@testable import ProviderBenchmark

@Suite("Gemma 4 production MTP validation matrix", .serialized)
struct GemmaMTPPerformanceLiveTests {
    @Test(
        "B=1/2/4/8 raw parity or production performance matrix",
        .enabled(
            if: MTPProductionLiveFixtures.enabled,
            MTPProductionLiveFixtures.disabledReason))
    func fullMatrix() async throws {
        let output = try MTPProductionLiveFixtures.benchmarkOutput()
        let bundle = try await MTPProductionLiveFixtures.loadBundle()
        let purpose = MTPProductionLiveFixtures.benchmarkPurpose
        let mtpExpectation = MTPProductionLiveFixtures.benchmarkMTPExpectation
        let report = try await MTPBenchmarkRunner.run(
            target: bundle.targetFacts,
            assistant: bundle.assistantFacts,
            hardware: try MTPBenchmarkModelFacts.hardware(),
            configuration: MTPBenchmarkConfiguration(
                prompts: try MTPProductionLiveFixtures.prompts(bundle: bundle),
                batchSizes: [1, 2, 4, 8],
                modes: MTPBenchmarkRunner.standardModes,
                maxTokensPerRow: MTPProductionLiveFixtures.benchmarkMaxTokens,
                purpose: purpose,
                mtpExpectation: mtpExpectation,
                stopPolicy: MTPProductionLiveFixtures.benchmarkStopPolicy(bundle: bundle),
                warmupIterations: MTPProductionLiveFixtures.benchmarkWarmupIterations,
                measurementRepetitions: MTPProductionLiveFixtures.benchmarkRepetitions,
                modeOrderSeed: MTPProductionLiveFixtures.benchmarkModeOrderSeed,
                runFingerprint: try MTPProductionLiveFixtures.benchmarkRunFingerprint(),
                checkpointDestination: output,
                deadline: MTPProductionLiveFixtures.benchmarkDeadline),
            sessions: bundle.makeSessionFactory())

        #expect(report.cases.count == 40)
        #expect(report.complete)
        #expect(report.purpose == purpose)
        #expect(report.mtpExpectation == mtpExpectation)
        #expect(report.cases.allSatisfy { $0.tokenParity })
        let requestedCases = report.cases.filter { $0.mode.requestsMTP }
        if mtpExpectation.expectsInactive {
            #expect(requestedCases.allSatisfy {
                !$0.metrics.active
                    && mtpExpectation.matchesInactiveReason($0.metrics.inactiveReason)
                    && $0.metrics.rounds == 0
                    && $0.metrics.proposedTokens == 0
                    && $0.metrics.acceptedDraftTokens == 0
            })
        } else {
            #expect(requestedCases.allSatisfy { $0.metrics.active })
        }
        if purpose == .rawParityStress {
            #expect(report.cases.allSatisfy {
                $0.medianAggregateDecodeTokensPerSecond == nil
                    && $0.rows.allSatisfy { $0.decodeTokensPerSecond == nil }
            })
        }
        print("[mtp-benchmark] wrote \(output.url.path)")
        MLX.Memory.clearCache()
    }
}
