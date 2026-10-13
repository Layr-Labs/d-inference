// Copyright © 2026 Eigen Labs.
//
// Host-only serving policy for LFM2.5-24B-A2B (`lfm2_moe`): the exact-ID
// advertise gate, paged KV and SSD complete-checkpoint defaults, the
// unmeasured activation reserve, artifact sampling defaults, MTP off, and the
// attention-only pre-load KV rate. Loaded-model capability checks live in
// `LFM25NativeAdapterTests`; these pin the defaults that must not regress.

import Foundation
import Testing

@testable import ProviderCore

private let lfmIDs = [
    EngineV2SupportedModels.lfm25_24bA2BModelID,
    EngineV2SupportedModels.lfm25_24bA2BRegistryModelID,
]

/// Same-family or look-alike ids that carry no onboarding evidence.
private let unqualifiedLFMIDs = [
    "LiquidAI/LFM2.5-8B-A1B-MLX-4bit", "LiquidAI/LFM2.5-24B-A2B",
    "LiquidAI/LFM2.5-24B-A2B-MLX-8bit", "mlx-community/LFM2.5-24B-A2B-4bit",
    "liquidai/lfm2.5-24b-a2b-mlx-4bit", "LFM2.5-24B-A2B", "lfm2.5-24b-a2b ",
    " lfm2.5-24b-a2b", "lfm2.5-24b-a2b-other", "lfm2.5-8b-a1b", "LiquidAI/LFM2-8B-A1B",
]

/// Facts from the pinned artifact config (667408d): 30 conv + 10 attention.
/// Shared with the native adapter tests, which decode it as the real
/// `LFM2MoEConfiguration`.
func lfm25PinnedConfigJSON() -> String {
    let types = (0..<40).map { $0 % 4 == 2 ? "\"full_attention\"" : "\"conv\"" }
    return """
        {"model_type":"lfm2_moe","vocab_size":128000,"num_hidden_layers":40,"hidden_size":2048,
         "num_attention_heads":32,"num_key_value_heads":8,"conv_L_cache":3,"conv_bias":false,
         "max_position_embeddings":131072,"num_experts":64,"num_experts_per_tok":4,
         "moe_intermediate_size":1536,"intermediate_size":11776,"num_dense_layers":2,
         "norm_eps":1e-05,"norm_topk_prob":true,"use_expert_bias":true,
         "routed_scaling_factor":1.0,"tie_word_embeddings":true,
         "rope_parameters":{"rope_theta":10000000.0,"rope_type":"default"},
         "layer_types":[\(types.joined(separator: ","))]}
        """
}

private func temporaryDirectory(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("lfm25-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func gateLoop(models: [ModelInfo]) throws -> ProviderLoop {
    let config = ProviderLoopConfig(
        coordinatorURL: "ws://127.0.0.1:0/ignored",
        hardware: HardwareInfo(
            machineModel: "Mac15,14", chipName: "Apple M3 Ultra", chipFamily: .m3, chipTier: .ultra,
            memoryGb: 256, memoryAvailableGb: 250,
            cpuCores: CpuCores(total: 32, performance: 24, efficiency: 8),
            gpuCores: 80, memoryBandwidthGbs: 819),
        models: models,
        config: ProviderConfig(
            provider: ProviderSettings(name: "lfm-gate-test", memoryReserveGB: 1),
            backend: BackendSettings(idleTimeoutMins: 0, maxModelSlots: 3),
            coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60)))
    return try ProviderLoop(config: config, attestationSigner: nil)
}

@Suite("LFM2.5-24B-A2B serving policy")
struct LFM25ServingPolicyTests {

    // MARK: advertise gate

    @Test("exact artifact and catalog ids are advertised; shared-type checkpoints are not")
    func exactAdvertiseGate() async throws {
        for id in lfmIDs {
            #expect(EngineV2SupportedModels.isLFM25ListingModelID(id))
            #expect(EngineV2SupportedModels.isSupported(
                model: ModelInfo(id: id, modelType: "lfm2_moe", sizeBytes: 1, estimatedMemoryGb: 1)))
            #expect(EngineV2SupportedModels.isSupported(
                model: ModelInfo(id: id, modelType: " LFM2_MOE\n", sizeBytes: 1, estimatedMemoryGb: 1)))
            // A qualified id is not a grant for another architecture.
            for type in [nil, "", "lfm2", "lfm2_vl", "qwen3"] as [String?] {
                #expect(!EngineV2SupportedModels.isSupported(
                    model: ModelInfo(id: id, modelType: type, sizeBytes: 1, estimatedMemoryGb: 1)))
            }
        }
        for id in unqualifiedLFMIDs {
            #expect(!EngineV2SupportedModels.isLFM25ListingModelID(id))
            #expect(!EngineV2SupportedModels.isSupported(
                model: ModelInfo(id: id, modelType: "lfm2_moe", sizeBytes: 1, estimatedMemoryGb: 1)))
        }
        // model_type alone never admits the family.
        #expect(!EngineV2SupportedModels.isSupported(modelType: "lfm2_moe"))

        let qualified = ModelInfo(
            id: EngineV2SupportedModels.lfm25_24bA2BModelID, modelType: "lfm2_moe",
            sizeBytes: 1 << 30, estimatedMemoryGb: 1.2)
        let small = ModelInfo(
            id: "LiquidAI/LFM2.5-8B-A1B-MLX-4bit", modelType: "lfm2_moe",
            sizeBytes: 1 << 30, estimatedMemoryGb: 1.2)
        let loop = try gateLoop(models: [qualified, small])
        #expect(await loop.isModelAdvertised(qualified.id))
        #expect(!(await loop.isModelAdvertised(small.id)))
    }

    // MARK: paged attention + prefix cache defaults

    @Test("automatic selection chooses paged KV; explicit operator choices still win")
    func pagedByDefault() {
        for id in lfmIDs {
            let parsed = EngineV2KVBackendPolicy.parseSelection(global: "auto", byModel: [:], modelID: id)
            #expect(parsed.selection == .auto)
            #expect(EngineV2KVBackendPolicy.preferredBackend(selection: .auto, modelID: id) == .paged)
            #expect(EngineV2KVBackendPolicy.preferredBackend(selection: .contiguous, modelID: id) == .contiguous)
            #expect(EngineV2KVBackendPolicy.degradesPagedFailure(selection: .auto))
        }
        for id in unqualifiedLFMIDs {
            #expect(EngineV2KVBackendPolicy.preferredBackend(selection: .auto, modelID: id) == .contiguous)
        }
    }

    @Test("SSD complete-checkpoint prefix cache defaults on and keeps its kill switch")
    func prefixCacheByDefault() throws {
        for id in lfmIDs {
            for value in [nil, "", "  "] as [String?] {
                let environment = value.map { [PrefixCachePolicy.environmentFlag: $0] } ?? [:]
                #expect(PrefixCachePolicy.isEnabled(modelId: id, environment: environment))
                // The resident RAM tier stays the fleet-wide explicit opt-in.
                #expect(!PrefixCachePolicy.isMemoryEnabled(environment: environment))
            }
            for value in ["0", "false", "off", "junk"] {
                #expect(!PrefixCachePolicy.isEnabled(
                    modelId: id, environment: [PrefixCachePolicy.environmentFlag: value]))
            }
        }
        for id in unqualifiedLFMIDs {
            #expect(!PrefixCachePolicy.isEnabled(modelId: id, environment: [:]))
        }
        // A default-on SSD load must take the fresh content-hash bracket.
        let directory = try temporaryDirectory("loadhash")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(lfm25PinnedConfigJSON().utf8).write(to: directory.appendingPathComponent("config.json"))
        for id in lfmIDs {
            #expect(PrefixCachePolicy.requiresLoadHashBracket(
                modelId: id, modelDirectory: directory, environment: [:]))
        }
        #expect(!PrefixCachePolicy.requiresLoadHashBracket(
            modelId: "LiquidAI/LFM2.5-8B-A1B-MLX-4bit", modelDirectory: directory, environment: [:]))
    }

    // MARK: MTP

    @Test("no MTP is requested automatically: no drafter exists for this artifact")
    func mtpOff() {
        for id in lfmIDs {
            for declared in [false, true] {
                #expect(!MTPMode.auto.enablesMTP(
                    forModelType: "lfm2_moe", embeddedArtifactDeclared: declared, modelID: id))
            }
            #expect(!MTPMode.auto.requiresCatalogPrewarm(forModelType: "lfm2_moe", modelID: id))
            #expect(!MTPMode.on.requiresCatalogPrewarm(forModelType: "lfm2_moe", modelID: id))
        }
    }

    // MARK: memory

    @Test("pre-load KV rate charges the 10 attention layers only, never the 30 conv layers")
    func attentionOnlyKVRate() throws {
        let directory = try temporaryDirectory("kv")
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.json")
        try Data(lfm25PinnedConfigJSON().utf8).write(to: config)
        let architecture = KVEstimation.parseModelArchitecture(at: config)
        #expect(architecture.numLayers == 40)
        #expect(architecture.kvHeads == 8)
        #expect(architecture.headDim == 64)
        #expect(architecture.maxContextLength == 131_072)
        #expect(architecture.layerTypes?.filter { $0 == "full_attention" }.count == 10)
        // 10 layers x (K+V) x 8 kv heads x 64 head_dim x fp16.
        let expected = 10 * 2 * 8 * 64 * 2
        #expect(KVEstimation.resolvedKVBytesPerToken(
            architecture: architecture, weightBytes: 13_567_188_992) == expected)
        #expect(expected == 20_480)
    }

    @Test("unmeasured activation reserve: the 5.5 GiB default, no invented floor")
    func activationReserveIsTheUnmeasuredDefault() {
        for id in lfmIDs {
            #expect(UnifiedMemoryCap.measuredActivationFloorsBytes[id] == nil)
            #expect(UnifiedMemoryCap.activationFloorBytes(forModelIDs: [id])
                == UnifiedMemoryCap.defaultActivationReserveBytes)
        }
        #expect(UnifiedMemoryCap.defaultActivationReserveBytes == 11 * 1024 * 1024 * 1024 / 2)
    }

    @Test("scanner LOAD estimate is resident weights with the standard load padding")
    func scannerLoadEstimate() throws {
        let cache = try temporaryDirectory("scan")
        defer { try? FileManager.default.removeItem(at: cache) }
        for name in ["LiquidAI--LFM2.5-24B-A2B-MLX-4bit", "LiquidAI--LFM2.5-8B-A1B-MLX-4bit"] {
            let snapshot = cache.appendingPathComponent("models--\(name)/snapshots/0123456789abcdef")
            try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
            try Data(lfm25PinnedConfigJSON().utf8).write(to: snapshot.appendingPathComponent("config.json"))
            try Data(count: 3 << 20).write(to: snapshot.appendingPathComponent("model.safetensors"))
        }
        let models = ModelScanner.scanAllModels(in: cache, environment: [:])
        let qualified = try #require(models.first { $0.id == EngineV2SupportedModels.lfm25_24bA2BModelID })
        #expect(qualified.modelType == "lfm2_moe")
        #expect(qualified.isVision == nil)
        #expect(qualified.sizeBytes == 3 << 20)
        #expect(abs(qualified.estimatedMemoryGb - Double(3 << 20) / 1_073_741_824 * 1.2) < 1e-9)
        #expect(EngineV2SupportedModels.partition(models).supported.map(\.id)
            == [EngineV2SupportedModels.lfm25_24bA2BModelID])
    }

    // MARK: sampling

    @Test("omitted sampling fields take the artifact generation_config defaults")
    func artifactSamplingDefaults() throws {
        for id in lfmIDs {
            #expect(EngineV2SamplingDefaults.honorsArtifactDefaults(modelId: id, modelType: "lfm2_moe"))
            #expect(!EngineV2SamplingDefaults.honorsArtifactDefaults(modelId: id, modelType: "lfm2"))
            #expect(!EngineV2SamplingDefaults.honorsArtifactDefaults(modelId: id, modelType: nil))
        }
        for id in unqualifiedLFMIDs {
            #expect(!EngineV2SamplingDefaults.honorsArtifactDefaults(modelId: id, modelType: "lfm2_moe"))
        }
        let directory = try temporaryDirectory("generation")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("""
            {"bos_token_id":124894,"eos_token_id":[124900],"pad_token_id":124893,
             "do_sample":true,"temperature":0.1,"top_k":50,"repetition_penalty":1.05}
            """.utf8).write(to: directory.appendingPathComponent("generation_config.json"))
        let defaults = EngineV2SamplingDefaults.resolve(
            modelId: EngineV2SupportedModels.lfm25_24bA2BModelID, modelType: "lfm2_moe",
            modelDirectory: directory)
        #expect(defaults == EngineV2SamplingDefaults(
            temperature: 0.1, topP: nil, topK: 50, repetitionPenalty: 1.05))
        #expect(EngineV2SamplingDefaults.resolve(
            modelId: "LiquidAI/LFM2.5-8B-A1B-MLX-4bit", modelType: "lfm2_moe",
            modelDirectory: directory) == .legacy)
    }
}
