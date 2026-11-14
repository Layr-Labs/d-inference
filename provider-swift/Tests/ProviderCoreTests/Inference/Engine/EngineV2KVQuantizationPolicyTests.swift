import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("EngineV2KVQuantizationPolicy")
struct EngineV2KVQuantizationPolicyTests {
    /// Muse Glimmer's restores must continue a cold prefill bit for bit, so its
    /// complete checkpoints store native rows whatever the global setting says.
    @Test func museGlimmerCheckpointsStoreNativeRows() throws {
        let key = EngineV2KVQuantizationPolicy.checkpointEnvironmentKey
        for id in [MuseGlimmerModelPolicy.localModelID, MuseGlimmerModelPolicy.catalogModelID] {
            func checkpoint(
                global: String? = nil, byModel: [String: String] = [:], environment: [String: String] = [:]
            ) throws -> EngineV2KVQuantizationSelection {
                try EngineV2KVQuantizationPolicy.resolveProviderCheckpoint(
                    modelType: MuseGlimmerModelPolicy.modelType, global: global, byModel: byModel,
                    modelID: id, environment: environment)
            }
            // The saved provider default and every global setting leave native rows.
            for global in [nil, "", "balanced", "k4v4", "k8v4", "k8v8", "native"] as [String?] {
                #expect(try checkpoint(global: global) == .native)
            }
            #expect(try checkpoint(global: "balanced", byModel: [id: " "], environment: [key: ""]) == .native)
            #expect(try checkpoint(byModel: ["another-model": "balanced"]) == .native)
            // The per-model setting, then the process switch, still select a profile.
            #expect(try checkpoint(byModel: [id: "balanced"]) == .balanced)
            #expect(try checkpoint(environment: [key: "k8v8"]) == .k8v8)
            #expect(try checkpoint(byModel: [id: "balanced"], environment: [key: "native"]) == .native)
            #expect(try checkpoint(byModel: [id: "k8v4"], environment: [key: " "]) == .k8v4)
            #expect(throws: EngineV2KVQuantizationPolicy.Failure.invalidCheckpointSelection("bogus")) {
                try checkpoint(byModel: [id: "bogus"])
            }
            // Live precision keeps the shared default.
            #expect(try EngineV2KVQuantizationPolicy.resolve(
                modelType: MuseGlimmerModelPolicy.modelType, modelID: id, environment: [:]) == .native)
        }
    }

    /// Every other model type resolves its checkpoints exactly as the shared policy does.
    @Test(arguments: ["gpt_oss", "qwen3_5", "gemma4", "nemotron_h", "flint", "mimo_v2", "supported", nil]
        as [String?])
    func otherCheckpointDefaultsAreUnchanged(modelType: String?) {
        let key = EngineV2KVQuantizationPolicy.checkpointEnvironmentKey
        let settings: [(global: String?, byModel: [String: String], environment: [String: String])] = [
            (nil, [:], [:]), ("balanced", [:], [:]), ("k8v4", [:], [:]), ("native", [:], [:]),
            (nil, ["m": "k8v8"], [:]), ("k8v8", ["m": " "], [:]), (nil, ["m": "balanced"], [:]),
            ("k8v8", [:], [key: "native"]), (nil, [:], [key: " "]), (nil, ["m": "bogus"], [:]),
        ]
        for setting in settings {
            let shared = Result {
                try EngineV2KVQuantizationPolicy.resolve(
                    modelType: modelType, global: setting.global, byModel: setting.byModel, modelID: "m",
                    environment: setting.environment, purpose: .checkpoint)
            }
            let provider = Result {
                try EngineV2KVQuantizationPolicy.resolveProviderCheckpoint(
                    modelType: modelType, global: setting.global, byModel: setting.byModel, modelID: "m",
                    environment: setting.environment)
            }
            #expect("\(shared)" == "\(provider)", "\(String(describing: modelType)) \(setting)")
        }
    }

    @Test(arguments: [
        "gpt-oss-20b", "Qwen3.5-9B", "ternary-bonsai-2-27b",
        "qwen3.6-35b-a3b-vl-mtp-mxfp8", "EigenLabs/Qwen3.8-27B-4bit-mtp",
        "gemma-4-26b", "gemma-4-26b-qat-4bit", "gemma-4-26b-8bit",
        "qwen3.5-35b-a3b", "nvidia-nemotron-3.5-lightning", "future-supported-model",
    ])
    func defaultIsGeometryIndependent(modelID: String) throws {
        let selection = try EngineV2KVQuantizationPolicy.resolve(
            modelType: "supported", modelID: modelID, environment: [:])
        #expect(selection == .native)
        #expect(selection.configuration == nil)
        let checkpoint = try EngineV2KVQuantizationPolicy.resolve(
            modelType: "supported", modelID: modelID, environment: [:], purpose: .checkpoint)
        #expect(checkpoint == .balanced)
        let configuration = try #require(checkpoint.configuration)
        #expect(configuration.keyBits == 4 && configuration.valueBits == 4)
        #expect(configuration.groupSize == 64)
        #expect(configuration.recentTokenCount == 128)
        #expect(configuration.resolvedRotationBlockSize(headDim: 192) == 64)
    }

    /// Served without its MTP head, Lightning keeps the exact checkpoint rows it
    /// stored beside the head, so a cache hit's output does not move.
    @Test func lightningCheckpointsDefaultToNative() throws {
        func checkpoint(
            global: String? = nil, byModel: [String: String] = [:], environment: [String: String] = [:]
        ) throws -> EngineV2KVQuantizationSelection {
            try EngineV2KVQuantizationPolicy.resolve(
                modelType: "nemotron_h", global: global, byModel: byModel, modelID: "m",
                environment: environment, purpose: .checkpoint)
        }
        let key = EngineV2KVQuantizationPolicy.checkpointEnvironmentKey
        // A saved provider.toml spells out the previous default, which is not a choice.
        for unset in [nil, "", " ", "balanced", " Balanced "] as [String?] {
            #expect(try checkpoint(global: unset) == .native)
        }
        #expect(try checkpoint(environment: [key: " "]) == .native)
        // Every explicit choice still wins, in the same order.
        #expect(try checkpoint(global: "k4v4") == .balanced)
        #expect(try checkpoint(global: "k8v4") == .k8v4)
        #expect(try checkpoint(byModel: ["m": "balanced"]) == .balanced)
        #expect(try checkpoint(environment: [key: "balanced"]) == .balanced)
        #expect(try checkpoint(global: "balanced", byModel: ["m": "k8v8"]) == .k8v8)
        #expect(try checkpoint(byModel: ["m": "balanced"], environment: [key: "native"]) == .native)
        // Live execution keeps its own default.
        #expect(try EngineV2KVQuantizationPolicy.resolve(
            modelType: "nemotron_h", global: "balanced", modelID: "m", environment: [:]) == .balanced)
        #expect(try EngineV2KVQuantizationPolicy.resolve(
            modelType: "nemotron_h", modelID: "m", environment: [:]) == .native)
    }

    @Test(arguments: [
        "qwen3_5", "gemma4", "gpt_oss", "glm5_next", "nemotron_h_omni", "prism_hadamard_qwen35", "supported",
    ])
    func otherFamiliesKeepTheirCheckpointDefault(modelType: String) throws {
        #expect(try EngineV2KVQuantizationPolicy.resolve(
            modelType: modelType, global: "balanced", modelID: "m", environment: [:], purpose: .checkpoint) == .balanced)
        #expect(try EngineV2KVQuantizationPolicy.resolve(
            modelType: modelType, modelID: "m", environment: [:], purpose: .checkpoint) == .balanced)
    }

    @Test(arguments: EngineV2KVQuantizationSelection.allCases.map(\.rawValue) + ["invalid"])
    func exactMiMoTypeIgnoresEveryOverride(raw: String) throws {
        #expect(try EngineV2KVQuantizationPolicy.resolve(
            modelType: "mimo_v2", global: raw, byModel: ["arbitrary-alias": raw],
            modelID: "arbitrary-alias",
            environment: [EngineV2KVQuantizationPolicy.environmentKey: raw]) == .native)
        #expect(try EngineV2KVQuantizationPolicy.resolve(
            modelType: "mimo_v2", global: raw, byModel: ["arbitrary-alias": raw],
            modelID: "arbitrary-alias",
            environment: [EngineV2KVQuantizationPolicy.checkpointEnvironmentKey: raw],
            purpose: .checkpoint) == .native)
    }

    @Test func storageOverridesAreIndependentAndErrorsNameTheirPurpose() throws {
        let environment = [
            EngineV2KVQuantizationPolicy.environmentKey: "native",
            EngineV2KVQuantizationPolicy.checkpointEnvironmentKey: "k8v8",
        ]
        #expect(try EngineV2KVQuantizationPolicy.resolve(
            modelType: nil, global: "balanced", modelID: "m", environment: environment) == .native)
        #expect(try EngineV2KVQuantizationPolicy.resolve(
            modelType: nil, global: "native", byModel: ["m": "k8v4"], modelID: "m",
            environment: [:], purpose: .checkpoint) == .k8v4)
        #expect(try EngineV2KVQuantizationPolicy.resolve(
            modelType: nil, global: "native", byModel: ["m": "k8v4"], modelID: "m",
            environment: environment, purpose: .checkpoint) == .k8v8)
        #expect(try EngineV2KVQuantizationPolicy.parseSelection(" ") == .native)
        #expect(try EngineV2KVQuantizationPolicy.parseSelection(" ", purpose: .checkpoint) == .balanced)
        #expect(throws: EngineV2KVQuantizationPolicy.Failure.invalidCheckpointSelection("invalid")) {
            try EngineV2KVQuantizationPolicy.parseSelection("invalid", purpose: .checkpoint)
        }
        #expect(EngineV2KVQuantizationPolicy.Failure.invalidSelection("invalid").description
            .contains("live KV"))
        #expect(EngineV2KVQuantizationPolicy.Failure.invalidCheckpointSelection("invalid").description
            .contains("checkpoint KV"))
    }

    @Test func precedenceAndNativeOverride() throws {
        #expect(try EngineV2KVQuantizationPolicy.resolve(
            modelType: nil, global: "native", byModel: ["m": "k8v4"],
            modelID: "m", environment: [:]) == .k8v4)
        #expect(try EngineV2KVQuantizationPolicy.resolve(
            modelType: nil, global: "balanced", byModel: ["m": "k8v4"], modelID: "m",
            environment: [EngineV2KVQuantizationPolicy.environmentKey: " OFF "]) == .native)
        #expect(try EngineV2KVQuantizationPolicy.parseSelection("k8v8").configuration?.valueBits == 8)
        #expect(EngineV2KVQuantizationSelection.native.configuration == nil)
        #expect(throws: EngineV2KVQuantizationPolicy.Failure.self) {
            try EngineV2KVQuantizationPolicy.parseSelection("k4v44")
        }
    }

    @Test func quantizedConstructionCannotSilentlyBecomeNativeContiguous() throws {
        try EngineV2KVQuantizationPolicy.requireResolvedBackend(.paged, selection: .balanced)
        try EngineV2KVQuantizationPolicy.requireResolvedBackend(.contiguous, selection: .native)
        for selection in [EngineV2KVQuantizationSelection.balanced, .k8v4, .k8v8] {
            #expect(throws: EngineV2KVQuantizationPolicy.Failure.self) {
                try EngineV2KVQuantizationPolicy.requireResolvedBackend(
                    .contiguous, selection: selection, reason: "kill_switch")
            }
        }
    }

    @Test func oldConfigurationDefaultsAndExplicitPrecisionRoundtrip() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(BackendSettings.self, from: Data("{}".utf8))
            .engineV2KVQuantization == "native")
        #expect(try decoder.decode(BackendSettings.self, from: Data("{}".utf8))
            .engineV2KVCheckpointQuantization == "balanced")
        let settings = BackendSettings(
            engineV2KVQuantization: "k8v4", engineV2KVQuantizationByModel: ["gpt-oss-20b": "native"])
        #expect(try decoder.decode(BackendSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    @Test func assistantNativeOwnersAndPhysicalMarginalRate() throws {
        let window = CBv2LayerKind(attention: .slidingWindow(1024), headDim: 64, kvHeads: 2, queryHeads: 4)
        let full = CBv2LayerKind(attention: .full, headDim: 64, kvHeads: 2, queryHeads: 4)
        let borrower = CBv2LayerKind(attention: .full, sharesKVWithLayer: 3,
            headDim: 64, kvHeads: 2, queryHeads: 4)
        let kinds = [window, full, window, full, borrower]
        #expect(EngineV2KVQuantizationPolicy.nativeAssistantAccessLayers(
            layerKinds: kinds, gemmaAssistantActive: false).isEmpty)
        let native = EngineV2KVQuantizationPolicy.nativeAssistantAccessLayers(
            layerKinds: kinds, gemmaAssistantActive: true)
        #expect(native == [2, 3])
        let format = try #require(EngineV2KVQuantizationSelection.balanced.configuration)
        let config = PagedKVPoolConfig(capacityBytes: 64 << 20,
            quantization: format, nativeLayerIndices: native)
        #expect(try EngineV2Factory.physicalFullKVBytesPerToken(
            layerKinds: kinds, dtypes: [.bfloat16, .bfloat16, .float32, .float32, .float32],
            config: config) == 1_184)
        // Pure target rate excludes windows, borrowed storage and assistant state.
        #expect(try EngineV2Factory.physicalFullKVBytesPerToken(
            layerKinds: [full], dtypes: [.float32], config: .init(
                capacityBytes: 64 << 20, quantization: format)) == 160)
    }
}
