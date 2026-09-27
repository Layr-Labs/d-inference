import Foundation
import MLXLLM
import Testing

@testable import ProviderCore

@Suite("Native Qwen4 qualified factory and media agreement")
struct Qwen4FactorySelectionTests {
    @Test func unqualifiedVisionConfigurationsRetainNativeTextFactory() {
        for type in ["qwen4_exp", "qwen4_exp_text"] {
            for overlay in [nil, false, true] as [Bool?] {
                var configuration: [String: Any] = [
                    "model_type": type,
                    "text_config": ["model_type": "qwen4_exp_text"],
                    "vision_config": ["hidden_size": 64],
                ]
                if let overlay { configuration["language_model_only"] = overlay }
                #expect(ModelContainerLoading.factorySelection(for: configuration) == .text)
            }
        }
    }

    @Test func scannerAndSlotRuntimeNeverAdvertiseNativeMedia() throws {
        for type in ["qwen4_exp", "qwen4_exp_text"] {
            for overlay in [nil, false, true] as [Bool?] {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("qwen4-media-scan-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                var configuration: [String: Any] = [
                    "model_type": type, "vision_config": ["hidden_size": 64],
                ]
                if let overlay { configuration["language_model_only"] = overlay }
                let original = try JSONSerialization.data(withJSONObject: configuration, options: .sortedKeys)
                let configURL = directory.appendingPathComponent("config.json")
                try original.write(to: configURL)

                #expect(!ModelScanner.configDeclaresVision(at: configURL))
                #expect(!ProviderLoop.modelIsVLM(at: directory))
                #expect(try Data(contentsOf: configURL) == original)
            }
        }
    }

    @Test func otherFamiliesRetainTheirFactorySelection() {
        for type in ["qwen3_5", "qwen3_5_moe", "qwen3_vl_moe", "gemma4"] {
            var configuration: [String: Any] = ["model_type": type]
            #expect(ModelContainerLoading.factorySelection(for: configuration) == .text)
            configuration["vision_config"] = ["hidden_size": 64]
            #expect(ModelContainerLoading.factorySelection(for: configuration) == .vision)
            configuration["language_model_only"] = true
            #expect(ModelContainerLoading.factorySelection(for: configuration) == .text)
        }
    }

    @Test func nativeTextCheckpointFilterExcludesVisionAndSSDWeights() {
        // Both native text factories bind this policy with keepVisionTower=false.
        // It is applied by the shared weight loader before array evaluation.
        let keep = Qwen4ExpCheckpointLoad.filter(mmapPLE: true, keepVisionTower: false)
        for key in ["model.visual.blocks.0.attn.qkv.weight", "vision_tower.patch_embed.weight",
            "mtp.fc_embedding.weight",
            "model.language_model.layers.1.ple.ple_embedding.ngram_embedding.shard_0.weight"]
        {
            #expect(!keep(key))
        }
        #expect(keep("model.language_model.layers.0.self_attn.q_proj.weight"))
    }
}
