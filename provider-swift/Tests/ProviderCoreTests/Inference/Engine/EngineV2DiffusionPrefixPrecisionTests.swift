import Foundation
import MLXLMCommon
import Testing

@testable import MLXVLM
@testable import ProviderCore

@Suite("Diffusion prefix precision guard")
struct EngineV2DiffusionPrefixPrecisionTests {
    @Test(arguments: [EngineV2KVQuantizationSelection.balanced, .k8v4, .k8v8])
    func packedPrefixRefusesBeforeResidentConfiguration(selection: EngineV2KVQuantizationSelection) async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let prepared = try await EngineV2SlotFactory.prepareDiffusionPrefixCache(
            modelId: "diffusion-fixture", modelDirectory: missing, weightHash: nil,
            kvBytesCapacity: 1 << 30, kvBudget: nil,
            environment: [PrefixCachePolicy.environmentFlag: "1",
                          PrefixCachePolicy.memoryEnvironmentFlag: "1"],
            persistentTestNamespace: nil, pageBacked: true, kvQuantization: selection)
        #expect(prepared.snapshots == nil && prepared.store == nil && !prepared.retainMemory)
        #expect(prepared.status.state == .disabled && prepared.status.reason == .unsupportedLayout)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func nativeDisabledPrefixPreservesExistingPolicy() async throws {
        let prepared = try await EngineV2SlotFactory.prepareDiffusionPrefixCache(
            modelId: "diffusion-fixture", modelDirectory: nil, weightHash: nil,
            kvBytesCapacity: 1 << 30, kvBudget: nil,
            environment: [PrefixCachePolicy.environmentFlag: "0"],
            persistentTestNamespace: nil, pageBacked: true, kvQuantization: .native)
        #expect(prepared.snapshots == nil && prepared.store == nil && !prepared.retainMemory)
        #expect(prepared.status.state == .disabled && prepared.status.reason == .configDisabled)
    }

    @Test(arguments: EngineV2KVQuantizationSelection.allCases, ["auto", "contiguous"])
    func factoryKeepsNativeCheckpointFallback(
        selection: EngineV2KVQuantizationSelection, backend: String
    ) async throws {
        let bundle = try await makeBundle(
            backend: backend, checkpoint: selection.rawValue)
        let engine = await bundle.bridge.ownedEngine as? CBv2NativeBlockEngine
        #expect(engine?.usesPagedStorage == false)
        #expect(await bundle.bridge.kvBackendKind == .contiguous)
        #expect(bundle.bridge.kvQuantization == .native)
        #expect(bundle.bridge.kvCheckpointQuantization == .native)
        await bundle.bridge.shutdown()
    }

    private enum CheckpointOverride: CaseIterable {
        case global, perModel, environment
    }

    @Test(arguments: CheckpointOverride.allCases, [false, true])
    private func malformedCheckpointFailsBeforeEngineAllocation(
        source: CheckpointOverride, cacheEnabled: Bool
    ) async throws {
        let invalid = "balnced"
        var environment = [
            PrefixCachePolicy.environmentFlag: cacheEnabled ? "1" : "0",
            PrefixCachePolicy.memoryEnvironmentFlag: cacheEnabled ? "1" : "0",
        ]
        if source == .environment {
            environment[EngineV2KVQuantizationPolicy.checkpointEnvironmentKey] = invalid
        }
        await #expect(throws: EngineV2KVQuantizationPolicy.Failure.invalidCheckpointSelection(invalid)) {
            // Fallthrough must fail with a different error, without allocating
            // a serving cache, even when prefix caching is disabled.
            let bundle = try await makeBundle(
                checkpoint: source == .global ? invalid : "balanced",
                byModel: source == .perModel ? ["diffusion-fixture": invalid] : [:],
                environment: environment, kvBytesCapacity: 0)
            await bundle.bridge.shutdown()
        }
    }

    @Test(arguments: [false, true])
    func factoryValidatesOnlyHighestPriorityCheckpointOverride(environmentWins: Bool) async throws {
        let bundle = try await makeBundle(
            checkpoint: "balnced",
            byModel: ["diffusion-fixture": environmentWins ? "balnced" : "balanced"],
            environment: environmentWins
                ? [EngineV2KVQuantizationPolicy.checkpointEnvironmentKey: "balanced"] : [:])
        let engine = await bundle.bridge.ownedEngine as? CBv2NativeBlockEngine
        #expect(engine?.usesPagedStorage == false)
        #expect(await bundle.bridge.kvBackendKind == .contiguous)
        #expect(bundle.bridge.kvQuantization == .native)
        #expect(bundle.bridge.kvCheckpointQuantization == .native)
        await bundle.bridge.shutdown()
    }

    private func makeBundle(
        backend: String = "auto", checkpoint: String = "balanced",
        byModel: [String: String] = [:], environment: [String: String] = [:],
        kvBytesCapacity: Int = 16 << 20
    ) async throws -> ProviderEngineBundle {
        _ = try #require(LiveInferenceFixtures.ensureMetallibColocated())
        let configuration = try JSONDecoder().decode(DiffusionGemmaConfiguration.self, from: Data(#"""
        {"model_type":"diffusion_gemma","canvas_length":4,"text_config":{
         "vocab_size":128,"hidden_size":32,"intermediate_size":48,"moe_intermediate_size":16,
         "num_hidden_layers":2,"num_attention_heads":4,"num_key_value_heads":2,
         "head_dim":64,"global_head_dim":64,"sliding_window":256,"max_position_embeddings":2048,
         "num_experts":4,"top_k_experts":2,"layer_types":["sliding_attention","full_attention"]}}
        """#.utf8))
        let tokenizer = StubBridgeTokenizer()
        let container = DiffusionGemmaContainer(context: DiffusionGemmaContext(
            configuration: .init(directory: FileManager.default.temporaryDirectory),
            model: DiffusionGemma(configuration),
            generationConfiguration: try .init(maxNewTokens: 4, maxDenoisingSteps: 4, eosTokenIds: []),
            tokenizer: tokenizer, chatTemplate: "unused", processor: nil))
        return try await EngineV2SlotFactory.makeProductionBundle(
            modelId: "diffusion-fixture", modelType: "diffusion_gemma", isVLM: false,
            modelDirectory: nil, container: .diffusion(container), tokenizer: TokenizerHandle(tokenizer),
            sizing: .init(weightsBytes: 1, fp16KVBytesPerToken: 512,
                maxContextLength: 2048, defaultMaxTokens: 4),
            kvBytesCapacity: kvBytesCapacity, maxConcurrentRequests: 1, kvBudget: nil,
            kvBackendConfig: backend, checkpointQuantizationConfig: checkpoint,
            checkpointQuantizationConfigByModel: byModel,
            specDecPreparation: .init(artifact: nil, status: .disabled(.targetUnsupported, configured: false)),
            environment: [PrefixCachePolicy.environmentFlag: "0", PrefixCachePolicy.memoryEnvironmentFlag: "0"]
                .merging(environment) { _, override in override },
            startServingTelemetry: false)
    }
}
