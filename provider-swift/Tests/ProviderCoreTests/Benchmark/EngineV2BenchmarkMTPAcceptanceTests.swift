import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import ProviderCoreFoundation
import Testing
@_spi(Benchmarking) @testable import ProviderCore

@Suite("Production benchmark MTP acceptance", .serialized)
struct EngineV2BenchmarkMTPAcceptanceTests {
    private struct Processor: UserInputProcessor {
        func prepare(input: UserInput) async throws -> LMInput { throw CancellationError() }
    }

    @Test func publicSessionInstallsDefaultExactAndExplicitTypicalAcceptance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("benchmark-mtp-acceptance-\(UUID().uuidString)")
        let targetDirectory = root.appendingPathComponent("target")
        let assistantDirectory = root.appendingPathComponent("assistant")
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: assistantDirectory, withIntermediateDirectories: true)

        let targetConfig = Data("""
            {"model_type":"gemma4_text","hidden_size":64,"num_hidden_layers":2,
             "intermediate_size":128,"num_attention_heads":2,"head_dim":64,
             "global_head_dim":64,"num_key_value_heads":1,"num_kv_shared_layers":0,
             "layer_types":["sliding_attention","full_attention"],"sliding_window":16,
             "final_logit_softcapping":30.0,"tie_word_embeddings":true,"vocab_size":128,
             "vocab_size_per_layer_input":128,"rms_norm_eps":1e-6,
             "hidden_size_per_layer_input":0,"use_double_wide_mlp":false}
            """.utf8)
        try targetConfig.write(to: targetDirectory.appendingPathComponent("config.json"))
        let target = Gemma4TextModel(try JSONDecoder().decode(
            Gemma4TextConfiguration.self, from: targetConfig))
        target.update(parameters: ModuleParameters.unflattened(
            target.parameters().flattened().map { ($0.0, $0.1.asType(.bfloat16)) }))
        eval(target)
        try MLX.save(arrays: Dictionary(uniqueKeysWithValues: target.parameters().flattened()),
            metadata: ["format": "mlx"], url: targetDirectory.appendingPathComponent("model.safetensors"))

        var assistantText = try #require(JSONSerialization.jsonObject(with: targetConfig) as? [String: Any])
        assistantText["num_kv_shared_layers"] = 2
        let assistantConfig = try JSONSerialization.data(withJSONObject: [
            "model_type": "gemma4_assistant", "backbone_hidden_size": 64,
            "use_ordered_embeddings": false, "num_centroids": 8,
            "centroid_intermediate_top_k": 2, "tie_word_embeddings": true,
            "text_config": assistantText,
        ])
        try assistantConfig.write(to: assistantDirectory.appendingPathComponent("config.json"))
        let assistant = try Gemma4AssistantDraftModel(config: JSONDecoder().decode(
            Gemma4AssistantConfiguration.self, from: assistantConfig))
        eval(assistant)
        try MLX.save(arrays: Dictionary(uniqueKeysWithValues: assistant.parameters().flattened()),
            metadata: ["format": "mlx"], url: assistantDirectory.appendingPathComponent("model.safetensors"))

        let modelID = "tiny/gemma-benchmark-acceptance"
        let tokenizer = StubBridgeTokenizer()
        let container = ModelContainer(context: ModelContext(
            configuration: ModelConfiguration(id: modelID), model: target,
            processor: Processor(), tokenizer: tokenizer))
        let weightHash = try #require(WeightHasher.computeHash(snapshotDir: targetDirectory))
        let environment = ["DARKBLOOM_PREFIX_CACHE": "0", "DARKBLOOM_PREFIX_CACHE_MEMORY": "0"]

        let defaultSession = try await EngineV2Factory.makeBenchmarkSession(
            modelId: modelID, modelDirectory: targetDirectory, isVLM: false,
            container: container, tokenizer: TokenizerHandle(tokenizer), verifiedWeightHash: weightHash,
            kvBytesCapacity: 64 << 20, mtpEnabled: true, assistantDirectory: assistantDirectory,
            kvBackendConfig: "contiguous", environment: environment)
        let defaultAcceptance = defaultSession.rawEngine.mtpMetricsSnapshot()?.acceptance
        await defaultSession.shutdown()
        #expect(defaultAcceptance == .exact)

        let typicalSession = try await EngineV2Factory.makeBenchmarkSession(
            modelId: modelID, modelDirectory: targetDirectory, isVLM: false,
            container: container, tokenizer: TokenizerHandle(tokenizer), verifiedWeightHash: weightHash,
            kvBytesCapacity: 64 << 20, mtpEnabled: true, mtpAcceptanceConfig: "typical",
            assistantDirectory: assistantDirectory, kvBackendConfig: "contiguous", environment: environment)
        let typicalAcceptance = typicalSession.rawEngine.mtpMetricsSnapshot()?.acceptance
        await typicalSession.shutdown()
        #expect(typicalAcceptance == .typical(delta: CBv2MTPAcceptance.defaultTypicalDelta))
    }
}
