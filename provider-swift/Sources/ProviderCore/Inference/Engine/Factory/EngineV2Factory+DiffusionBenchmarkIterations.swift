import Foundation
import MLXLMCommon
import MLXVLM
import ProviderCoreFoundation

extension EngineV2Factory {
    static func runDiffusionBenchmarkIterations(
        container: DiffusionGemmaContainer, engine: CBv2NativeBlockEngine,
        budget: GlobalKVCacheBudget, modelID: String, prompt: String,
        iterations: Int, maxTokens: Int, stopTokens: Set<Int>
    ) async throws -> [DiffusionGemmaBenchmarkIteration] {
        let body = try JSONSerialization.data(withJSONObject: [
            "model": modelID, "messages": [["role": "user", "content": prompt]],
            "temperature": 1, "max_tokens": maxTokens, "seed": 341,
            "reasoning": ["enabled": false],
        ])
        let date = PromptRenderDate.capture()
        var results = [DiffusionGemmaBenchmarkIteration]()
        let routeProbe = DiffusionBenchmarkRouteProbe()
        defer { routeProbe.finish() }
        for index in 0..<iterations {
            try Task.checkCancellation()
            try routeProbe.begin(iteration: index)
            let start = ContinuousClock.now
            let prepared = try await container.perform { context in
                try benchmarkPrompt(body: body, tokenizer: context.tokenizer,
                    modelType: "diffusion_gemma", defaultDate: date)
            }
            var request = CBv2Request(id: .init(UInt64(index + 1)), promptTokens: prepared.tokens,
                sampling: prepared.sampling, maxTokens: maxTokens, stopTokens: stopTokens,
                prefixCacheEnabled: false)
            let reservationID = "native-benchmark-\(index)"
            // Same estimator and ownership split as the normal bridge: native
            // paged admission owns its process charge; contiguous needs a claim.
            let bytes = try engine.estimatedRequestBytes(request)
            if !engine.usesProcessMemoryOwner {
                guard await budget.reserveBytes(requestID: reservationID, bytes: UInt64(bytes)) else {
                    throw DiffusionBenchmarkFailure.insufficientMemory
                }
                request.nativeReservationBytes = bytes
            }
            do {
                let stream = try engine.submit(request)
                var ids = [Int](), text = "", usage: CBv2Usage?, reason: CBv2FinishReason?
                for await event in stream {
                    switch event {
                    case .delta(let chunk, let tokens, _): text += chunk; ids += tokens
                    case .finished(let finish, let counts): reason = finish; usage = counts
                    }
                }
                // Cancellation can terminate the AsyncStream consumer before
                // native retirement. Drain the engine before refunding anything.
                if Task.isCancelled {
                    await engine.shutdown()
                    throw CancellationError()
                }
                guard reason == .stop || reason == .length else { throw DiffusionBenchmarkFailure.unexpectedFinish }
                guard let usage, usage.completionTokens == ids.count,
                    usage.timing.promptComputedNanos > 0, usage.timing.finishedNanos > usage.timing.promptComputedNanos else {
                    throw DiffusionBenchmarkFailure.inconsistentUsage
                }
                if reason == .stop, let last = ids.last, stopTokens.contains(last) { ids.removeLast() }
                let sample = DiffusionGemmaBenchmarkIteration(tokenIDs: ids, text: text, usage: usage,
                    totalMilliseconds: diffusionMilliseconds(ContinuousClock.now - start))
                try routeProbe.end(iteration: index)
                await budget.release(requestID: reservationID)
                results.append(sample)
            } catch {
                await engine.shutdown()
                await budget.release(requestID: reservationID)
                throw error
            }
        }
        return results
    }
}
