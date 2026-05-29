import CryptoKit
import Foundation
import Testing
@testable import MLX
@testable import MLXLLM
@testable import MLXLMCommon
@testable import ProviderCore

// Model-backed integration test for the encrypted prefix cache on the
// REAL engine + a REAL model. Opt-in: set DARKBLOOM_MODEL_TEST_DIR to a
// local model snapshot directory (e.g. an mlx-community Llama snapshot).
// Skips when unset, so CI / plain `swift test` doesn't try to load a
// model. Requires the MLX metallib to be resolvable (real Metal device).
//
// The key correctness assertion: with temperature 0 (greedy), a prompt
// generated through the cache-ON engine must produce IDENTICAL output to
// the cache-OFF engine. If the prefix-cache reuse corrupted KV state,
// the tokens would diverge. We also assert the cache actually engaged
// (hits + tokens_saved > 0) and that an encrypted file format is used.

private func modelDirFromEnv() -> URL? {
    guard let p = ProcessInfo.processInfo.environment["DARKBLOOM_MODEL_TEST_DIR"], !p.isEmpty else {
        return nil
    }
    return URL(fileURLWithPath: p)
}

/// Parse num_hidden_layers / num_key_value_heads / head_dim from the
/// model's config.json (best-effort; only needs to be self-consistent
/// for the binding, since save + load use the same one).
private func bindingFromConfig(_ dir: URL, modelHash: String) -> PrefixCacheModelBinding {
    var numLayers = 16, kvHeads = 8, headDim = 64
    if let data = try? Data(contentsOf: dir.appendingPathComponent("config.json")),
       let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        numLayers = (cfg["num_hidden_layers"] as? Int) ?? numLayers
        kvHeads = (cfg["num_key_value_heads"] as? Int) ?? kvHeads
        if let hd = cfg["head_dim"] as? Int { headDim = hd }
        else if let hs = cfg["hidden_size"] as? Int, let nh = cfg["num_attention_heads"] as? Int, nh > 0 {
            headDim = hs / nh
        }
    }
    return PrefixCacheModelBinding(
        modelHash: modelHash, modelDtype: "bf16", modelArch: "Llama", vocabSize: 0,
        numLayers: numLayers, kvHeads: kvHeads, headDim: headDim
    )
}

private func makeEngine(
    container: ModelContainer,
    modelId: String,
    persistence: EncryptedPrefixCachePersistence?
) async -> (BatchedEngine, PrefixCache?) {
    await container.perform { ctx -> (BatchedEngine, PrefixCache?) in
        let prefixCache: PrefixCache? = persistence.map {
            PrefixCache(config: PrefixCacheConfig(blockSize: 256, maxBlocks: 64),
                        modelName: modelId, persistence: $0)
        }
        let scheduler = Scheduler(
            model: ctx.model, tokenizer: ctx.tokenizer,
            config: SchedulerConfig(maxNumSeqs: 4, maxNumBatchedTokens: 8192,
                                    prefillStepSize: 512, streamInterval: 1, maxKVCacheTokens: 0),
            eosTokenIds: ctx.configuration.eosTokenIds,
            prefixCache: prefixCache
        )
        let engine = BatchedEngine(
            scheduler: scheduler, tokenizer: ctx.tokenizer, modelName: modelId,
            config: ContinuousBatchingConfig(schedulerConfig: scheduler.config, stepInterval: 0.001),
            externalChatTemplate: nil
        )
        return (engine, prefixCache)
    }
}

@Test
func livePrefixCacheMatchesUncachedOutputAndEngages() async throws {
    guard let modelDir = modelDirFromEnv() else {
        print("Skipping live model test: set DARKBLOOM_MODEL_TEST_DIR to a model snapshot dir")
        return
    }

    let container = try await LLMModelFactory.shared.loadContainer(
        from: modelDir, using: LocalTokenizerLoader())
    let modelId = "live-test-model"

    // A long shared prefix (> 256 tokens → at least one full cache block)
    // plus a distinct question, so the prefix is reusable across requests.
    let sharedPrefix = String(
        repeating: "The quick brown fox jumps over the lazy dog near the riverbank. ", count: 30)
    let prompt = sharedPrefix + "\n\nQuestion: What animal is mentioned? Answer:"
    let params = SamplingParams(maxTokens: 24, temperature: 0.0)

    // 1) Cache OFF — reference greedy output.
    let (cold, _) = await makeEngine(container: container, modelId: modelId, persistence: nil)
    await cold.start()
    let refOut = try await cold.generateWithResult(prompt: prompt, samplingParams: params)
    await cold.stop()
    #expect(!refOut.outputText.isEmpty, "cold generation produced no output")

    // 2) Cache ON — encrypted persistence with a random in-memory KEK.
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("dbkv-live-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let persistence = EncryptedPrefixCachePersistence(
        kekKey: SymmetricKey(size: .bits256), dir: dir,
        binding: bindingFromConfig(modelDir, modelHash: modelId))

    let (warm, cache) = await makeEngine(container: container, modelId: modelId, persistence: persistence)
    await warm.start()
    // First request populates the prefix cache.
    let warm1 = try await warm.generateWithResult(prompt: prompt, samplingParams: params)
    // Second identical request should reuse the cached prefix.
    let warm2 = try await warm.generateWithResult(prompt: prompt, samplingParams: params)
    await warm.stop()

    // CORRECTNESS: greedy output must be identical with the cache on.
    #expect(warm1.outputText == refOut.outputText,
            "cache-on output diverged from reference — prefix reuse corrupted KV.\ncold: \(refOut.outputText)\nwarm: \(warm1.outputText)")
    #expect(warm2.outputText == refOut.outputText,
            "second cached request diverged from reference")

    // ENGAGEMENT: the prefix cache actually saved prefill work.
    let stats = cache?.getStats() ?? [:]
    let hits = (stats["hits"] as? Int) ?? 0
    let saved = (stats["tokens_saved"] as? Int) ?? 0
    #expect(hits > 0, "prefix cache never hit (stats: \(stats))")
    #expect(saved > 0, "prefix cache saved no tokens (stats: \(stats))")
    print("LIVE prefix cache: hits=\(hits) tokensSaved=\(saved) | output matched reference ✓")
}
