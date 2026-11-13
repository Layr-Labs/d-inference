// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// Every list that names Muse Glimmer 30B reads `MuseGlimmerModelPolicy`.
/// These pin each list for both working identities and for a look-alike.
@Suite("Muse Glimmer policy lists")
struct MuseGlimmerPolicyTests {
    private static let ids = [MuseGlimmerModelPolicy.catalogModelID, MuseGlimmerModelPolicy.localModelID]
    private static let type = MuseGlimmerModelPolicy.modelType
    /// Same family name, not an admitted identity.
    private static let lookalikes = ["meta-models/Muse-Glimmer-30B", "muse-glimmer-30b-bf16", "Muse-Glimmer-30B"]

    private func model(_ id: String, _ type: String?) -> ModelInfo {
        ModelInfo(id: id, modelType: type, sizeBytes: 1, estimatedMemoryGb: 1)
    }

    @Test("the identity is exact ids plus the model type")
    func identity() {
        #expect(Self.ids == ["muse-glimmer-30b", "nvidia/Muse-Glimmer-30B-NVFP4"])
        #expect(Self.type == "muse_glimmer")
        for id in Self.ids {
            #expect(MuseGlimmerModelPolicy.matchesModelID(id))
            #expect(MuseGlimmerModelPolicy.matches(modelId: id, modelType: " Muse_Glimmer "))
            #expect(!MuseGlimmerModelPolicy.matches(modelId: id, modelType: "muse_glimmer_text"))
            #expect(!MuseGlimmerModelPolicy.matches(modelId: id, modelType: nil))
        }
        for id in Self.lookalikes {
            #expect(!MuseGlimmerModelPolicy.matchesModelID(id))
            #expect(!MuseGlimmerModelPolicy.matches(modelId: id, modelType: Self.type))
        }
        #expect(!MuseGlimmerModelPolicy.matchesModelID(nil))
    }

    @Test("the advertised context is the trained window, bounded by the loaded model")
    func contextLimit() {
        for id in Self.ids {
            #expect(MuseGlimmerModelPolicy.contextLimit(
                modelId: id, modelType: Self.type, nativeContextTokens: 131_072) == 131_072)
            #expect(MuseGlimmerModelPolicy.contextLimit(
                modelId: id, modelType: Self.type, nativeContextTokens: 262_144) == 131_072)
            #expect(MuseGlimmerModelPolicy.contextLimit(
                modelId: id, modelType: Self.type, nativeContextTokens: 32_768) == 32_768)
            #expect(MuseGlimmerModelPolicy.contextLimit(
                modelId: id, modelType: Self.type, nativeContextTokens: 0) == nil)
        }
        #expect(MuseGlimmerModelPolicy.contextLimit(
            modelId: "other", modelType: Self.type, nativeContextTokens: 131_072) == nil)
    }

    @Test("the family is not advertised before the engine can serve it")
    func notYetInTheSupportedSet() {
        // The engine adapter for this type arrives with the SDK's native
        // model. Until then no provider may advertise or load it.
        #expect(!EngineV2SupportedModels.isSupported(modelType: Self.type))
        for id in Self.ids {
            #expect(!EngineV2SupportedModels.isSupported(model: model(id, Self.type)))
        }
    }

    @Test("automatic KV selection is paged")
    func pagedByDefault() {
        for id in Self.ids {
            #expect(EngineV2KVBackendPolicy.preferredBackend(selection: .auto, modelID: id) == .paged)
            #expect(EngineV2KVBackendPolicy.preferredBackend(selection: .contiguous, modelID: id) == .contiguous)
        }
        for id in Self.lookalikes {
            #expect(EngineV2KVBackendPolicy.preferredBackend(selection: .auto, modelID: id) == .contiguous)
        }
    }

    @Test("the SSD prefix cache defaults on and the kill switch still wins")
    func prefixCacheDefault() {
        for id in Self.ids {
            #expect(PrefixCachePolicy.isEnabled(modelId: id, environment: [:]))
            #expect(!PrefixCachePolicy.isEnabled(modelId: id, environment: ["DARKBLOOM_PREFIX_CACHE": "0"]))
        }
        for id in Self.lookalikes {
            #expect(!PrefixCachePolicy.isEnabled(modelId: id, environment: [:]))
        }
    }

    @Test("automatic MTP names the exact target and its published drafter")
    func automaticMTP() {
        for id in Self.ids {
            #expect(MTPMode.auto.enablesMTP(forModelType: Self.type, embeddedArtifactDeclared: false, modelID: id))
            #expect(MTPMode.auto.requiresCatalogPrewarm(forModelType: Self.type, modelID: id))
            #expect(!MTPMode.off.enablesMTP(forModelType: Self.type, embeddedArtifactDeclared: false, modelID: id))
            #expect(!MTPMode.auto.enablesMTP(forModelType: "gemma4", embeddedArtifactDeclared: false, modelID: id))
        }
        for id in Self.lookalikes {
            #expect(!MTPMode.auto.enablesMTP(forModelType: Self.type, embeddedArtifactDeclared: false, modelID: id))
        }
    }

    @Test("draft depth adapts up to seven and never past the engine's tested window")
    func draftDepth() {
        #expect(MuseGlimmerModelPolicy.maximumDraftTokens == 7)
        for id in Self.ids {
            for stateful in [true, false] {
                let policy = MTPAutomaticVerificationPolicy.draftDepthPolicy(
                    usesRequestStatefulDrafter: stateful, modelID: id)
                #expect(policy.maximum == min(7, CBv2MTPConfig.testedMaxDraftTokens))
                #expect(policy.maximum <= CBv2MTPConfig.testedMaxDraftTokens)
                #expect(policy.fixed == nil)
            }
        }
        // Another model's policy is unchanged.
        let other = MTPAutomaticVerificationPolicy.draftDepthPolicy(usesRequestStatefulDrafter: false, modelID: "other")
        #expect(other.maximum == CBv2MTPConfig.testedMaxDraftTokens && other.fixed == 1)
    }

    @Test("the built-in acceptance rule is exact; configuration still overrides it")
    func acceptance() {
        for id in Self.ids {
            #expect(MTPAcceptancePolicy.builtInIsExact(modelID: id))
            #expect(MTPAcceptancePolicy.resolve(global: nil, byModel: [:], modelID: id).acceptance == .exact)
            #expect(MTPAcceptancePolicy.resolve(global: "typical", byModel: [:], modelID: id).acceptance
                == .typical(delta: CBv2MTPAcceptance.defaultTypicalDelta))
        }
        for id in Self.lookalikes { #expect(!MTPAcceptancePolicy.builtInIsExact(modelID: id)) }
    }

    @Test("omitted sampling fields take the model card's values, whatever the artifact's file says")
    func samplingDefaults() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-glimmer-sampling-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // The NVIDIA repository's generation_config.json.
        try Data(#"{"bos_token_id": 200000, "do_sample": false, "eos_token_id": [200001, 200008]}"#.utf8)
            .write(to: directory.appendingPathComponent("generation_config.json"))
        let card = EngineV2SamplingDefaults(temperature: 1.0, topP: 0.95, topK: 64)
        for id in Self.ids {
            for location in [directory, nil] {
                #expect(EngineV2SamplingDefaults.resolve(
                    modelId: id, modelType: Self.type, modelDirectory: location) == card)
            }
            #expect(EngineV2SamplingDefaults.resolve(
                modelId: id, modelType: "gemma4", modelDirectory: directory).isLegacy)
        }
        for id in Self.lookalikes {
            #expect(EngineV2SamplingDefaults.resolve(
                modelId: id, modelType: Self.type, modelDirectory: directory).isLegacy)
        }
        #expect(card.repetitionPenalty == nil && card.presencePenalty == nil)
    }

    @Test("the scan labels the exact identity nvfp4")
    func quantizationLabel() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-glimmer-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"model_type":"muse_glimmer"}"#.utf8).write(to: directory.appendingPathComponent("config.json"))
        // Discovery reads the file size, never the tensors.
        try Data([0]).write(to: directory.appendingPathComponent("model.safetensors"))
        for id in Self.ids {
            let info = try #require(ModelScanner.parseModelInfo(snapshotDir: directory, modelName: id))
            #expect(info.quantization == "nvfp4")
            #expect(info.modelType == Self.type)
        }
        let other = try #require(ModelScanner.parseModelInfo(snapshotDir: directory, modelName: Self.lookalikes[0]))
        #expect(other.quantization == nil)
    }
}
