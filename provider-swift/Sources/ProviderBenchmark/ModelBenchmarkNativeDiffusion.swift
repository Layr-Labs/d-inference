import Foundation
@_spi(Benchmarking) import ProviderCore

extension ModelBenchmark {
    static func usesNativeBlockGeneration(modelType: String?) -> Bool { modelType == "diffusion_gemma" }

    static func runNativeDiffusion(
        modelID: String, directory: URL, prompt: String, iterations: Int,
        maxTokens: Int, backend: String
    ) async throws -> [BenchmarkIterationResult] {
        let report = try await EngineV2Factory.runDiffusionGemmaBenchmark(
            modelID: modelID, directory: directory, prompt: prompt,
            iterations: iterations, maxTokens: maxTokens, backend: backend)
        print("Native diffusion: prefix cache off, precision \(report.kvQuantization), reasoning off, seed 341, unchanged checkpoint denoising recipe.")
        print("Generation TPS includes first-block work and excludes terminal EOS; native framing tokens may remain.")
        print("This is not a finalized-visible-token performance-target certification.")
        var results = [BenchmarkIterationResult]()
        for (index, sample) in report.iterations.enumerated() {
            let record = try DiffusionGemmaBenchmarkRow(
                iteration: index + 1, report: report, sample: sample,
                runtimeIdentity: EngineV2Factory.benchmarkRuntimeIdentity())
            print("NATIVE_BLOCK_BENCHMARK " + (try record.jsonString()))
            results.append(.init(iteration: index + 1, promptTokens: sample.usage.promptTokens,
                completionTokens: sample.usage.completionTokens,
                prefillLatencyMs: sample.prefillMilliseconds,
                decodeTokensPerSecond: sample.committedTokensPerSecond,
                totalTimeMs: sample.totalMilliseconds))
        }
        return results
    }
}
