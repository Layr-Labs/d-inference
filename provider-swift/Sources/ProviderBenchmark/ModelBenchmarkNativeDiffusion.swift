import CryptoKit
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
        print("Native diffusion baseline: cache off, reasoning off, seed 341, unchanged checkpoint denoising recipe.")
        print("Generation TPS includes first-block work and excludes terminal EOS; native framing tokens may remain.")
        print("This is not a finalized-visible-token performance-target certification.")
        var results = [BenchmarkIterationResult]()
        for (index, sample) in report.iterations.enumerated() {
            let record: [String: Any] = [
                "iteration": index + 1, "backend": report.backend, "weightHash": report.weightHash,
                "loadIncludingIntegrityMilliseconds": report.loadMilliseconds,
                "promptTokens": sample.usage.promptTokens,
                "completionTokensIncludingEOS": sample.usage.completionTokens,
                "committedTokensExcludingEOS": sample.tokenIDs.count,
                "prefillMilliseconds": sample.prefillMilliseconds,
                "firstCommittedMilliseconds": sample.firstCommittedMilliseconds,
                "generationIncludingFirstBlockMilliseconds": sample.generationMilliseconds,
                "committedTokensPerSecond": sample.committedTokensPerSecond,
                "totalMilliseconds": sample.totalMilliseconds,
                "observedBatchRowsMax": sample.usage.timing.batchRowsMax,
                // Already-recorded native work diagnostics, not output tokens.
                // Reading them adds no sampling or GPU evaluation step.
                "nativeExecutionQuanta": sample.usage.timing.batchRowsSum,
                "nativePrefillQuanta": sample.usage.timing.prefillChunks,
                "committedBlocksAfterFirst": sample.usage.timing.decodeSteps,
                "nativeQuantumWallNanoseconds": sample.usage.timing.stepLatencyNanosSum,
                "nativeQuantumMaxWallNanoseconds": sample.usage.timing.stepLatencyNanosMax,
                "committedTokenSHA256": SHA256.hash(data: try JSONEncoder().encode(sample.tokenIDs))
                    .map { String(format: "%02x", $0) }.joined(),
                "rawTextSHA256": SHA256.hash(data: Data(sample.text.utf8))
                    .map { String(format: "%02x", $0) }.joined(),
                "kvGrantBytes": report.grant.grantBytes, "speedTargetQualified": false,
            ]
            print("NATIVE_BLOCK_BENCHMARK " + String(decoding: try JSONSerialization.data(
                withJSONObject: record, options: [.sortedKeys]), as: UTF8.self))
            results.append(.init(iteration: index + 1, promptTokens: sample.usage.promptTokens,
                completionTokens: sample.usage.completionTokens,
                prefillLatencyMs: sample.prefillMilliseconds,
                decodeTokensPerSecond: sample.committedTokensPerSecond,
                totalTimeMs: sample.totalMilliseconds))
        }
        return results
    }
}
