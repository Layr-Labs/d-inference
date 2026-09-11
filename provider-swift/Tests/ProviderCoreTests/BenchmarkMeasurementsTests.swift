import Foundation
import Testing

@testable import ProviderBenchmark

@Suite("Benchmark measurement arithmetic")
struct BenchmarkMeasurementsTests {
    @Test("wall time includes whole seconds", arguments: [0, 1, 999, 1_000, 2_250, 120_125, -2_250])
    func wallTime(milliseconds: Int) {
        #expect(BenchmarkMeasurements.milliseconds(.milliseconds(milliseconds)) == Double(milliseconds))
    }

    @Test("sub-millisecond timing retains fractional precision")
    func fractionalWallTime() {
        #expect(abs(BenchmarkMeasurements.milliseconds(.microseconds(123)) - 0.123) < 1e-12)
    }

    @Test("median uses both middle samples without mutating or filtering observations")
    func medianConventions() {
        let observations = [100.0, 3, 1, 2]
        #expect(BenchmarkMeasurements.median(observations) == 2.5)
        #expect(observations == [100, 3, 1, 2])
        #expect(BenchmarkMeasurements.median([100, 1, 3]) == 3)
        #expect(BenchmarkMeasurements.median([42.5]) == 42.5)
        #expect(BenchmarkMeasurements.median([]) == 0)
        #expect(BenchmarkMeasurements.median([1, .infinity]).isInfinite)
        #expect(BenchmarkMeasurements.mean([1, .nan]).isNaN)
    }

    @Test("model reports average durations and retain integer token averages")
    func reportAverages() {
        let report = BenchmarkReport(
            modelID: "test/model", modelPath: "/test", prompt: "test",
            iterations: [
                BenchmarkIterationResult(iteration: 1, promptTokens: 3, completionTokens: 5,
                    prefillLatencyMs: 2_250, decodeTokensPerSecond: 10, totalTimeMs: 2_750),
                BenchmarkIterationResult(iteration: 2, promptTokens: 4, completionTokens: 6,
                    prefillLatencyMs: 3_750, decodeTokensPerSecond: 20, totalTimeMs: 4_250),
            ],
            hardwareDescription: "test"
        )
        #expect(report.avgPrefillLatencyMs == 3_000)
        #expect(report.avgDecodeTokensPerSecond == 15)
        #expect(report.avgTotalTimeMs == 3_500)
        #expect(report.avgPromptTokens == 3)
        #expect(report.avgCompletionTokens == 5)

        let empty = BenchmarkReport(modelID: "test", modelPath: "/test", prompt: "test",
            iterations: [], hardwareDescription: "test")
        #expect(empty.avgPrefillLatencyMs == 0)
        #expect(empty.avgDecodeTokensPerSecond == 0)
        #expect(empty.avgTotalTimeMs == 0)
    }
}
