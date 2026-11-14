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

    @Test("only the exact identity is advertised; the type alone never is")
    func supportedSet() {
        for id in Self.ids {
            #expect(EngineV2SupportedModels.isSupported(model: model(id, Self.type)))
            #expect(!EngineV2SupportedModels.isSupported(model: model(id, "muse_glimmer_text")))
        }
        // A renamed or look-alike copy of the architecture is never advertised.
        for id in Self.lookalikes {
            #expect(!EngineV2SupportedModels.isSupported(model: model(id, Self.type)))
        }
        #expect(!EngineV2SupportedModels.isSupported(modelType: Self.type))
        let (supported, unsupported) = EngineV2SupportedModels.partition(
            [model(Self.ids[0], Self.type), model(Self.lookalikes[0], Self.type)])
        #expect(supported.map(\.id) == [Self.ids[0]] && unsupported.map(\.id) == [Self.lookalikes[0]])
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

    @Test("draft depth is a fixed seven by default, adaptive when selected, never past the tested window")
    func draftDepth() {
        #expect(MuseGlimmerModelPolicy.maximumDraftTokens == 7)
        let key = MTPAutomaticVerificationPolicy.museGlimmerDraftDepthEnvironmentKey
        #expect(key == "DARKBLOOM_MTP_MUSE_GLIMMER_DEPTH")
        let cap = min(7, CBv2MTPConfig.testedMaxDraftTokens)
        let cases: [([String: String], Int?, String?)] = [
            ([:], cap, nil), ([key: ""], cap, nil), ([key: "fixed"], cap, nil), ([key: " FIXED "], cap, nil),
            ([key: "adaptive"], nil, nil), ([key: "Adaptive"], nil, nil), ([key: "seven"], cap, "seven"),
        ]
        for id in Self.ids {
            for stateful in [true, false] {
                for (environment, fixed, unrecognized) in cases {
                    let policy = MTPAutomaticVerificationPolicy.draftDepthPolicy(
                        usesRequestStatefulDrafter: stateful, modelID: id, environment: environment)
                    #expect(policy.maximum == cap)
                    #expect(policy.maximum <= CBv2MTPConfig.testedMaxDraftTokens)
                    #expect(policy.fixed == fixed, "\(environment)")
                    #expect(MTPAutomaticVerificationPolicy.museGlimmerDraftDepth(environment: environment)
                        .unrecognized == unrecognized)
                }
            }
        }
        // Without the argument the default holds.
        #expect(MTPAutomaticVerificationPolicy.draftDepthPolicy(
            usesRequestStatefulDrafter: true, modelID: Self.ids[0]).fixed == cap)
        // Another model's policy is unchanged, the variable set or not.
        for environment in [[:], [key: "adaptive"], [key: "fixed"]] as [[String: String]] {
            let other = MTPAutomaticVerificationPolicy.draftDepthPolicy(
                usesRequestStatefulDrafter: false, modelID: "other", environment: environment)
            #expect(other.maximum == CBv2MTPConfig.testedMaxDraftTokens && other.fixed == 1)
            let stateful = MTPAutomaticVerificationPolicy.draftDepthPolicy(
                usesRequestStatefulDrafter: true, modelID: "other", environment: environment)
            #expect(stateful.maximum == CBv2MTPConfig.testedMaxDraftTokens && stateful.fixed == nil)
        }
        for id in Self.lookalikes {
            let policy = MTPAutomaticVerificationPolicy.draftDepthPolicy(
                usesRequestStatefulDrafter: false, modelID: id, environment: [key: "fixed"])
            #expect(policy.fixed == MTPAutomaticVerificationPolicy.initialDraftTokens)
        }
    }

    @Test("two decoding requests may share a speculative round at depth three; one row is the default")
    func speculativeRows() {
        let key = MTPAutomaticVerificationPolicy.museGlimmerSpeculativeRowsEnvironmentKey
        #expect(key == "DARKBLOOM_MTP_MUSE_GLIMMER_ROWS")
        #expect(MuseGlimmerModelPolicy.pairedRoundDraftTokens == 3)
        let paired = MTPAutomaticVerificationPolicy.MuseGlimmerSpeculativeRows.paired
        let single = MTPAutomaticVerificationPolicy.MuseGlimmerSpeculativeRows.single
        #expect(paired.rows == 2 && paired.depthByDecodeRows == [7, 3])
        #expect(single.rows == 1 && single.depthByDecodeRows == nil)
        // Two rows of 1 + 3 columns are the 8 verify rows one row of depth 7 takes.
        #expect(paired.rows * (paired.depthByDecodeRows![1] + 1) == MuseGlimmerModelPolicy.maximumDraftTokens + 1)
        let cases: [([String: String], MTPAutomaticVerificationPolicy.MuseGlimmerSpeculativeRows, String?)] = [
            ([:], single, nil), ([key: ""], single, nil), ([key: "1"], single, nil), ([key: " 1\n"], single, nil),
            ([key: "2"], paired, nil), ([key: " 2 "], paired, nil),
            ([key: "3"], single, "3"), ([key: "two"], single, "two"), ([key: "0"], single, "0"),
        ]
        for (environment, expected, unrecognized) in cases {
            let resolved = MTPAutomaticVerificationPolicy.museGlimmerSpeculativeRows(environment: environment)
            #expect(resolved.rows == expected, "\(environment)")
            #expect(resolved.unrecognized == unrecognized, "\(environment)")
        }
        let depthKey = MTPAutomaticVerificationPolicy.museGlimmerDraftDepthEnvironmentKey
        for id in Self.ids {
            // Fixed depth, paired: the table applies and the batch is the row count.
            // One row (the default) leaves the configuration as it was (the drafter binds one row).
            let base = CBv2MTPConfig().maxSpeculativeBatch
            for (environment, rows, table) in [
                ([:], base, nil), ([key: "1"], base, nil), ([key: "2"], 2, [7, 3]),
            ] as [([String: String], Int, [Int]?)] {
                let depth = MTPAutomaticVerificationPolicy.draftDepthPolicy(
                    usesRequestStatefulDrafter: true, modelID: id, environment: environment)
                var config = CBv2MTPConfig(enabled: true, maxDraftTokens: depth.maximum, fixedDraftTokens: depth.fixed)
                let unrecognized = MTPAutomaticVerificationPolicy.applyMuseGlimmerSpeculativeRows(
                    to: &config, modelID: id, environment: environment)
                #expect(unrecognized == nil)
                #expect(config.maxSpeculativeBatch == rows, "\(environment)")
                #expect(config.fixedDraftTokensByDecodeRows == table, "\(environment)")
                #expect(config.fixedDraftTokens == 7 && config.maxDraftTokens == 7)
            }
            // Adaptive depth, paired: two rows, no table (the controller keys its own row buckets).
            var adaptive = CBv2MTPConfig(enabled: true, maxDraftTokens: 7, fixedDraftTokens: nil)
            _ = MTPAutomaticVerificationPolicy.applyMuseGlimmerSpeculativeRows(
                to: &adaptive, modelID: id, environment: [depthKey: "adaptive", key: "2"])
            #expect(adaptive.maxSpeculativeBatch == 2 && adaptive.fixedDraftTokensByDecodeRows == nil)
            var adaptiveDefault = CBv2MTPConfig(enabled: true, maxDraftTokens: 7, fixedDraftTokens: nil)
            _ = MTPAutomaticVerificationPolicy.applyMuseGlimmerSpeculativeRows(
                to: &adaptiveDefault, modelID: id, environment: [depthKey: "adaptive"])
            #expect(adaptiveDefault.maxSpeculativeBatch == base && adaptiveDefault.fixedDraftTokensByDecodeRows == nil)
            // An unreadable value keeps the default and is reported.
            var odd = CBv2MTPConfig(enabled: true, maxDraftTokens: 7, fixedDraftTokens: 7)
            #expect(MTPAutomaticVerificationPolicy.applyMuseGlimmerSpeculativeRows(
                to: &odd, modelID: id, environment: [key: "4"]) == "4")
            #expect(odd.maxSpeculativeBatch == base && odd.fixedDraftTokensByDecodeRows == nil)
        }
        // Every other model's configuration is untouched, the variable set or not.
        for id in Self.lookalikes + ["other"] {
            for environment in [[:], [key: "1"], [key: "2"]] as [[String: String]] {
                var config = CBv2MTPConfig(enabled: true, maxDraftTokens: 7, fixedDraftTokens: 1)
                #expect(MTPAutomaticVerificationPolicy.applyMuseGlimmerSpeculativeRows(
                    to: &config, modelID: id, environment: environment) == nil)
                #expect(config.maxSpeculativeBatch == CBv2MTPConfig().maxSpeculativeBatch)
                #expect(config.fixedDraftTokensByDecodeRows == nil)
            }
        }
    }

    @Test("sampled rows propose the argmax by default; 1 couples them to their verify noise")
    func coupledProposals() {
        let key = MTPAutomaticVerificationPolicy.museGlimmerCoupledProposalsEnvironmentKey
        #expect(key == "DARKBLOOM_MTP_MUSE_GLIMMER_COUPLED")
        let cases: [([String: String], Bool, String?)] = [
            ([:], false, nil), ([key: ""], false, nil), ([key: "0"], false, nil), ([key: "\t0\n"], false, nil),
            ([key: "1"], true, nil), ([key: " 1 "], true, nil),
            ([key: "on"], false, "on"), ([key: "2"], false, "2"), ([key: "true"], false, "true"),
        ]
        for (environment, coupled, unrecognized) in cases {
            let resolved = MTPAutomaticVerificationPolicy.museGlimmerCoupledProposals(environment: environment)
            #expect(resolved.coupled == coupled, "\(environment)")
            #expect(resolved.unrecognized == unrecognized, "\(environment)")
        }
    }

    @Test("the drafter takes one pass per request by default; 1 batches a step's requests")
    func batchedRequests() {
        let key = MTPAutomaticVerificationPolicy.museGlimmerBatchedRequestsEnvironmentKey
        #expect(key == "DARKBLOOM_MTP_MUSE_GLIMMER_BATCHED")
        let cases: [([String: String], Bool, String?)] = [
            ([:], false, nil), ([key: ""], false, nil), ([key: "0"], false, nil), ([key: "\t0\n"], false, nil),
            ([key: "1"], true, nil), ([key: " 1 "], true, nil),
            ([key: "on"], false, "on"), ([key: "2"], false, "2"), ([key: "true"], false, "true"),
        ]
        for (environment, batched, unrecognized) in cases {
            let resolved = MTPAutomaticVerificationPolicy.museGlimmerBatchedRequests(environment: environment)
            #expect(resolved.batched == batched, "\(environment)")
            #expect(resolved.unrecognized == unrecognized, "\(environment)")
        }
    }

    @Test("wide opts in to rounds of up to four requests, two drafts each at three or four rows")
    func wideRounds() {
        let key = MTPAutomaticVerificationPolicy.museGlimmerSpeculativeRowsEnvironmentKey
        let wide = MTPAutomaticVerificationPolicy.MuseGlimmerSpeculativeRows.wide
        #expect(MuseGlimmerModelPolicy.wideRoundDraftTokens == 2)
        #expect(wide.rows == 4 && wide.depthByDecodeRows == [7, 3, 2, 2])
        // The widest round verifies 12 target rows, inside one 16-row verify piece.
        #expect(wide.rows * (wide.depthByDecodeRows!.last! + 1) == 12)
        for raw in ["wide", " wide\n"] {
            let resolved = MTPAutomaticVerificationPolicy.museGlimmerSpeculativeRows(environment: [key: raw])
            #expect(resolved.rows == wide && resolved.unrecognized == nil, "\(raw)")
        }
        let depthKey = MTPAutomaticVerificationPolicy.museGlimmerDraftDepthEnvironmentKey
        for id in Self.ids {
            var config = CBv2MTPConfig(enabled: true, maxDraftTokens: 7, fixedDraftTokens: 7)
            #expect(MTPAutomaticVerificationPolicy.applyMuseGlimmerSpeculativeRows(
                to: &config, modelID: id, environment: [key: "wide"]) == nil)
            #expect(config.maxSpeculativeBatch == 4 && config.fixedDraftTokensByDecodeRows == [7, 3, 2, 2])
            var adaptive = CBv2MTPConfig(enabled: true, maxDraftTokens: 7, fixedDraftTokens: nil)
            _ = MTPAutomaticVerificationPolicy.applyMuseGlimmerSpeculativeRows(
                to: &adaptive, modelID: id, environment: [key: "wide", depthKey: "adaptive"])
            #expect(adaptive.maxSpeculativeBatch == 4 && adaptive.fixedDraftTokensByDecodeRows == nil)
        }
        for id in Self.lookalikes + ["other"] {
            var config = CBv2MTPConfig(enabled: true, maxDraftTokens: 7, fixedDraftTokens: 1)
            #expect(MTPAutomaticVerificationPolicy.applyMuseGlimmerSpeculativeRows(
                to: &config, modelID: id, environment: [key: "wide"]) == nil)
            #expect(config.maxSpeculativeBatch == CBv2MTPConfig().maxSpeculativeBatch)
        }
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
