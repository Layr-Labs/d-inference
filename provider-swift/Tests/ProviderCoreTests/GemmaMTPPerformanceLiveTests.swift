import MLX
import Testing

@testable import ProviderBenchmark

@Suite("Gemma 4 production MTP validation matrix", .serialized)
struct GemmaMTPPerformanceLiveTests {
    @Test(
        "raw parity or production performance matrix over the configured modes and batch sizes",
        .enabled(
            if: MTPProductionLiveFixtures.enabled,
            MTPProductionLiveFixtures.disabledReason))
    func fullMatrix() async throws {
        let output = try MTPProductionLiveFixtures.benchmarkOutput()
        let bundle = try await MTPProductionLiveFixtures.loadBundle()
        let purpose = MTPProductionLiveFixtures.benchmarkPurpose
        let mtpExpectation = MTPProductionLiveFixtures.benchmarkMTPExpectation
        let batchSizes = MTPProductionLiveFixtures.benchmarkBatchSizes
        let modes = try MTPProductionLiveFixtures.benchmarkModes()
        let parityPolicy = MTPProductionLiveFixtures.benchmarkParityPolicy
        let prompts = try MTPProductionLiveFixtures.prompts(bundle: bundle)
        print("[mtp-benchmark] prompt token counts: \(prompts.map(\.tokenIDs.count))")
        let report = try await MTPBenchmarkRunner.run(
            target: bundle.targetFacts,
            assistant: bundle.assistantFacts,
            hardware: try MTPBenchmarkModelFacts.hardware(),
            configuration: MTPBenchmarkConfiguration(
                prompts: prompts,
                batchSizes: batchSizes,
                modes: modes,
                maxTokensPerRow: MTPProductionLiveFixtures.benchmarkMaxTokens,
                purpose: purpose,
                mtpExpectation: mtpExpectation,
                stopPolicy: MTPProductionLiveFixtures.benchmarkStopPolicy(bundle: bundle),
                warmupIterations: MTPProductionLiveFixtures.benchmarkWarmupIterations,
                measurementRepetitions: MTPProductionLiveFixtures.benchmarkRepetitions,
                modeOrderSeed: MTPProductionLiveFixtures.benchmarkModeOrderSeed,
                runFingerprint: try MTPProductionLiveFixtures.benchmarkRunFingerprint(),
                parityPolicy: parityPolicy,
                allowsRawFixedLengthPerformance:
                    MTPProductionLiveFixtures.benchmarkUsesRawStopPolicy,
                longContextEvidence:
                    MTPProductionLiveFixtures.benchmarkLongContextEvidence,
                checkpointDestination: output,
                deadline: MTPProductionLiveFixtures.benchmarkDeadline),
            sessions: bundle.makeSessionFactory())

        #expect(report.cases.count == modes.count * batchSizes.count)
        #expect(report.complete)
        #expect(report.purpose == purpose)
        #expect(report.mtpExpectation == mtpExpectation)
        // Under `.enforce` the runner has already thrown on any divergence, so
        // this is the certification assertion. Under `.record` divergence is
        // the measurement's output, not its failure: the case carries the rows
        // and the first divergence position, and the arm still reports tok/s.
        if parityPolicy == .enforce {
            #expect(report.cases.allSatisfy { $0.tokenParity })
        } else {
            for result in report.cases where !result.tokenParity {
                print(
                    "[mtp-benchmark] parity divergence \(result.mode.label) B=\(result.batchSize): "
                        + result.parityDivergences.map {
                            "row \($0.row) first=\($0.firstDivergenceIndex.map(String.init) ?? "prefix") "
                                + "base=\($0.baselineTokenCount)/\($0.baselineFinishReason) "
                                + "cand=\($0.candidateTokenCount)/\($0.candidateFinishReason)"
                        }.joined(separator: "; "))
            }
        }
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
