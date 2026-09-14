import Foundation
import Testing
import MLX
import MLXLMCommon
import MLXVLM
@testable import ProviderCore

/// Live Gemma4 26B-A4B decode profile.
///
/// Gated because it loads the local 26B model.
/// Run with:
///   DARKBLOOM_LIVE_MLX_TESTS=1 DARKBLOOM_LIVE_MLX_GEMMA=1 \
///   DARKBLOOM_GEMMA_MODEL=mlx-community/gemma-4-26b-a4b-it-8bit \
///   swift test --filter Gemma4DecodeProfileTests
///
/// Set `DARKBLOOM_GEMMA_PRINT_TEXT=1` to print a short decoded sample.
@Suite("Gemma4 decode profile", .serialized)
struct Gemma4DecodeProfileTests {
    @Test(
        "B=1 raw decode TPS",
        .enabled(if:
            ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_TESTS"] != nil
                && ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_GEMMA"] != nil
        )
    )
    func rawDecodeB1() async throws {
        if LiveInferenceFixtures.ensureMetallibColocated() == nil {
            Issue.record("mlx.metallib not found near test bundle or in MLX_METALLIB_PATH/SOURCE")
            return
        }
        MLX.GPU.set(memoryLimit: 96 * 1024 * 1024 * 1024)

        let modelID = ProcessInfo.processInfo.environment["DARKBLOOM_GEMMA_MODEL"]
            ?? "mlx-community/gemma-4-26b-a4b-it-8bit"
        guard let modelDir = ModelScanner.resolveLocalPath(modelID: modelID) else {
            Issue.record("model '\(modelID)' is not in the local cache")
            return
        }

        let container = try await VLMModelFactory.shared.loadContainer(
            from: modelDir, using: LocalTokenizerLoader())

        let prompt = "Write a detailed technical explanation of sparse mixture-of-experts inference on Apple Silicon."
        let encoded: [Int] = try await container.perform { ctx in
            try ctx.tokenizer.applyChatTemplate(
                messages: [["role": "user", "content": prompt]],
                tools: nil,
                additionalContext: nil)
        }

        let tps: Double = await container.perform { ctx in
            let cache = ctx.model.newCache(parameters: nil)
            let promptArray = MLXArray(encoded.map { Int32($0) }).reshaped([1, encoded.count])

            var logits = ctx.model.callAsFunction(promptArray, cache: cache)
            var nextToken = argMax(logits[0..., -1, 0...], axis: -1)
            asyncEval(nextToken)

            let warmups = 8
            for _ in 0 ..< warmups {
                logits = ctx.model.callAsFunction(nextToken.reshaped([1, 1]), cache: cache)
                let sampled = argMax(logits[0..., -1, 0...], axis: -1)
                asyncEval(sampled)
                eval(nextToken)
                nextToken = sampled
            }

            let tokens = 128
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0 ..< tokens {
                logits = ctx.model.callAsFunction(nextToken.reshaped([1, 1]), cache: cache)
                let sampled = argMax(logits[0..., -1, 0...], axis: -1)
                asyncEval(sampled)
                eval(nextToken)
                nextToken = sampled
            }
            eval(nextToken)

            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
            let msPerToken = elapsedMs / Double(tokens)
            return 1_000.0 / msPerToken
        }

        print("[gemma4-decode-profile] model=\(modelID) prompt_tokens=\(encoded.count) raw_b1_tps=\(String(format: "%.1f", tps))")

        if ProcessInfo.processInfo.environment["DARKBLOOM_GEMMA_PRINT_TEXT"] != nil {
            let text: String = await container.perform { ctx in
                let cache = ctx.model.newCache(parameters: nil)
                let promptArray = MLXArray(encoded.map { Int32($0) }).reshaped([1, encoded.count])
                var logits = ctx.model.callAsFunction(promptArray, cache: cache)
                var nextToken = argMax(logits[0..., -1, 0...], axis: -1)
                asyncEval(nextToken)

                var generated: [Int] = []
                generated.reserveCapacity(64)
                for _ in 0 ..< 64 {
                    eval(nextToken)
                    let token = nextToken.item(Int.self)
                    generated.append(token)
                    logits = ctx.model.callAsFunction(nextToken.reshaped([1, 1]), cache: cache)
                    let sampled = argMax(logits[0..., -1, 0...], axis: -1)
                    asyncEval(sampled)
                    nextToken = sampled
                }
                return ctx.tokenizer.decode(tokenIds: generated, skipSpecialTokens: true)
            }
            print("[gemma4-decode-profile] sample=\(text)")
        }
    }
}
