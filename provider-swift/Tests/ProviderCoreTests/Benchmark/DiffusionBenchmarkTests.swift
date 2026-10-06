import Foundation
import MLXLMCommon
import Testing

@_spi(Benchmarking) @testable import ProviderCore

struct DiffusionBenchmarkTests {
    @Test func blockThroughputIncludesTheWholeFirstCanvasAndExcludesEOS() {
        var usage = CBv2Usage(promptTokens: 42, completionTokens: 257)
        usage.timing.prefillFirstLaunchNanos = 1_000_000
        usage.timing.promptComputedNanos = 101_000_000
        usage.timing.firstTokenNanos = 1_101_000_000
        usage.timing.finishedNanos = 1_201_000_000
        let sample = DiffusionGemmaBenchmarkIteration(tokenIDs: Array(repeating: 7, count: 256),
            text: "synthetic", usage: usage, totalMilliseconds: 1300)
        #expect(sample.prefillMilliseconds == 100)
        #expect(sample.firstCommittedMilliseconds == 1101)
        #expect(sample.generationMilliseconds == 1100)
        #expect(abs(sample.committedTokensPerSecond - 256 / 1.1) < 1e-10)
        #expect(sample.committedTokensPerSecond < 257 / 0.1,
            "Never divide an entire committed block by its short post-burst tail")
    }

    @Test func missingOrInvalidPromptClockDoesNotInventThroughput() {
        var usage = CBv2Usage(promptTokens: 1, completionTokens: 1)
        usage.timing.finishedNanos = 20
        let emptyClock = DiffusionGemmaBenchmarkIteration(tokenIDs: [7], text: "x", usage: usage,
            totalMilliseconds: 1)
        #expect(emptyClock.committedTokensPerSecond == 0)
        usage.timing.promptComputedNanos = 30
        let reversed = DiffusionGemmaBenchmarkIteration(tokenIDs: [7], text: "x", usage: usage,
            totalMilliseconds: 1)
        #expect(reversed.generationMilliseconds == 0 && reversed.committedTokensPerSecond == 0)
    }

    @Test func invalidArgumentsAndWrongArchitectureRefuseBeforeRuntimeConstruction() async {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for (iterations, tokens, backend) in [(0, 8, "auto"), (1, 0, "auto"), (1, 8, "other")] {
            await #expect(throws: EngineV2Factory.DiffusionBenchmarkFailure.self) {
                try await EngineV2Factory.runDiffusionGemmaBenchmark(modelID: "fixture", directory: missing,
                    prompt: "fixture", iterations: iterations, maxTokens: tokens, backend: backend)
            }
        }
        await #expect(throws: EngineV2Factory.DiffusionBenchmarkFailure.self) {
            try await EngineV2Factory.runDiffusionGemmaBenchmark(modelID: "fixture", directory: missing,
                prompt: "fixture", iterations: 1, maxTokens: 8)
        }
    }
}
