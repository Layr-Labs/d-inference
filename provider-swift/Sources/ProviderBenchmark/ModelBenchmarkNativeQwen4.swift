import Foundation
import MLXLLM
import MLXLMCommon
@_spi(Benchmarking) import ProviderCore
import ProviderCoreFoundation

struct ModelBenchmarkDeclaration: Decodable {
    let modelType: String?
    enum CodingKeys: String, CodingKey { case modelType = "model_type" }
}

extension ModelBenchmark {
    enum Failure: Error, Equatable {
        case invalidArguments, modelHashMismatch, unexpectedFinish, missingUsage, runtimeIdentityUnavailable
    }

    static func validateArguments(iterations: Int, maxTokens: Int) throws {
        guard iterations > 0, maxTokens > 0 else { throw Failure.invalidArguments }
    }

    static func usesNativeGeneration(modelType: String?) -> Bool {
        Qwen4ExpPLEResidency.isQwen4ExpModelType(modelType)
    }

    static func decodedModelType(from data: Data) throws -> String? {
        // Preserve the same JSON5 contract as both existing SDK factories.
        try JSONDecoder.json5().decode(ModelBenchmarkDeclaration.self, from: data).modelType
    }

    static func nativeRequestBody(modelID: String, prompt: String, maxTokens: Int) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "model": modelID, "messages": [["role": "user", "content": prompt]],
            "temperature": 0.6, "top_p": 1.0, "top_k": 0, "min_p": 0.0,
            "max_tokens": maxTokens,
        ])
    }

    static func milliseconds(_ duration: Duration) -> Double {
        BenchmarkMeasurements.milliseconds(duration)
    }

    /// Target-only uncached baseline, matching the ordinary command's scope.
    /// Native CBv2 owns QSA, PLE and cache state; TokenIterator does not.
    /// The separate MTP benchmark remains the explicit speculation comparison.
    static func runNativeQwen4(
        modelID: String, modelDirectory: URL,
        prompt: String, iterations: Int, maxTokens: Int
    ) async throws -> [BenchmarkIterationResult] {
        guard let verified = WeightHasher.computeHash(snapshotDir: modelDirectory, modelID: modelID)
        else { throw Failure.modelHashMismatch }
        let modelType = try decodedModelType(
            from: Data(contentsOf: modelDirectory.appendingPathComponent("config.json")))
        guard usesNativeGeneration(modelType: modelType) else { throw Failure.modelHashMismatch }
        guard bindRuntimeMetallibForMLX() != nil, selfBinaryHash() != nil
        else { throw Failure.runtimeIdentityUnavailable }
        let loaded = try await EngineV2Factory.loadBenchmarkContainer(
            modelID: modelID, directory: modelDirectory)
        do {
            guard WeightHasher.computeHash(snapshotDir: modelDirectory, modelID: modelID) == verified
            else { throw Failure.modelHashMismatch }
            let tokenizer = await loaded.container.perform { TokenizerHandle($0.tokenizer) }
            var environment = ProcessInfo.processInfo.environment
            environment["DARKBLOOM_PREFIX_CACHE"] = "0"
            environment["DARKBLOOM_PREFIX_CACHE_MEMORY"] = "0"
            let session = try await EngineV2Factory.makeBenchmarkSession(
                modelId: modelID, modelDirectory: modelDirectory, isVLM: loaded.isVLM,
                container: loaded.container, tokenizer: tokenizer, verifiedWeightHash: verified,
                kvBytesCapacity: 1 << 30, maxConcurrentRequests: 1, mtpEnabled: false,
                useProductionKVGrant: true, requirePersistentKey: false, environment: environment)
            do {
                print("Model loaded. Native CBv2 baseline (MTP off, prefix cache off, \(session.backend)).")
                let body = try nativeRequestBody(modelID: modelID, prompt: prompt, maxTokens: maxTokens)
                let date = PromptRenderDate.capture()
                let stopTokens = await session.stopTokenIDs()
                var results: [BenchmarkIterationResult] = []
                for iteration in 1...iterations {
                    try Task.checkCancellation()
                    print("Iteration \(iteration)/\(iterations)...")
                    let start = ContinuousClock.now
                    let prepared = try await loaded.container.perform { context in
                        try EngineV2Factory.benchmarkPrompt(body: body, tokenizer: context.tokenizer,
                            modelType: modelType, defaultDate: date)
                    }
                    let submission = try await session.submit(CBv2Request(
                        id: CBv2RequestID(UInt64(iteration)), promptTokens: prepared.tokens,
                        sampling: prepared.sampling, maxTokens: maxTokens,
                        stopTokens: stopTokens, prefixCacheEnabled: false))
                    var firstToken: ContinuousClock.Instant?
                    var usage: CBv2Usage?
                    var reason: CBv2FinishReason?
                    for await event in submission.events {
                        switch event {
                        case .delta(_, let tokens, _):
                            if !tokens.isEmpty, firstToken == nil { firstToken = .now }
                        case .finished(let finish, let finalUsage):
                            reason = finish
                            usage = finalUsage
                        }
                    }
                    await session.complete(receiptID: submission.receiptID)
                    try Task.checkCancellation()
                    guard reason == .stop || reason == .length else { throw Failure.unexpectedFinish }
                    guard let usage else { throw Failure.missingUsage }
                    let end = ContinuousClock.now
                    let total = milliseconds(end - start)
                    let prefill = firstToken.map { milliseconds($0 - start) } ?? total
                    let decode = max(0, total - prefill)
                    results.append(BenchmarkIterationResult(
                        iteration: iteration, promptTokens: usage.promptTokens,
                        completionTokens: usage.completionTokens, prefillLatencyMs: prefill,
                        decodeTokensPerSecond: decode > 0
                            ? Double(max(0, usage.completionTokens - 1)) * 1000 / decode : 0,
                        totalTimeMs: total))
                }
                await session.shutdown()
                await EngineV2Factory.releaseBenchmarkContainer(loaded.container)
                return results
            } catch {
                await session.shutdown()
                throw error
            }
        } catch {
            await EngineV2Factory.releaseBenchmarkContainer(loaded.container)
            throw error
        }
    }
}
