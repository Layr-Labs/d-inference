import Foundation
import Testing

@testable import ProviderBenchmark

@Suite("standard model benchmark")
struct ModelBenchmarkTests {
    @Test(
        "iteration timings retain whole seconds",
        arguments: [
            (
                Duration.milliseconds(900),
                Duration.seconds(2) + .milliseconds(100),
                900.0,
                2_100.0,
                213.33333333333334
            ),
            (
                Duration.seconds(2) + .milliseconds(168),
                Duration.seconds(4),
                2_168.0,
                4_000.0,
                139.73799126637555
            ),
            (
                Duration.milliseconds(168),
                Duration.milliseconds(900),
                168.0,
                900.0,
                349.7267759562842
            ),
        ] as [(Duration, Duration, Double, Double, Double)]
    )
    func iterationTimingsRetainWholeSeconds(
        prefill: Duration,
        total: Duration,
        expectedPrefillMs: Double,
        expectedTotalMs: Double,
        expectedTPS: Double
    ) {
        let result = ModelBenchmark.iterationResult(
            iteration: 1,
            promptTokens: 12,
            completionTokens: 256,
            prefillElapsed: prefill,
            infoPromptTimeSeconds: 0,
            totalElapsed: total
        )

        #expect(abs(result.prefillLatencyMs - expectedPrefillMs) < 1e-9)
        #expect(abs(result.totalTimeMs - expectedTotalMs) < 1e-9)
        #expect(abs(result.decodeTokensPerSecond - expectedTPS) < 1e-9)
    }

    @Test("iteration uses generation prompt timing when no chunk arrives")
    func iterationUsesGenerationPromptTimingWithoutChunk() {
        let result = ModelBenchmark.iterationResult(
            iteration: 2,
            promptTokens: 12,
            completionTokens: 0,
            prefillElapsed: nil,
            infoPromptTimeSeconds: 1.25,
            totalElapsed: .seconds(3)
        )

        #expect(result.prefillLatencyMs == 1_250)
        #expect(result.totalTimeMs == 3_000)
        #expect(result.decodeTokensPerSecond == 0)
    }
}
