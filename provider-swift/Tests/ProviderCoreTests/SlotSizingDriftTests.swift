// Copyright © 2026 Eigen Labs.
//
// Drift tests for the two independent fp16 KV-rate derivations the v0.7.5
// slot lifecycle uses:
//
//   * `SlotSizingSnapshot.fp16KVBytesPerToken(layerKinds:)` — the ENGINE
//     TRUTH: the long-context marginal rate of `AdmissionV2.estimatedBytes`
//     over the model's own `cbv2LayerKinds`. Sizes engine grants, shared-
//     budget reservations, and heartbeat token budgets.
//   * `BatchScheduler.resolvedKVBytesPerToken(architecture:weightBytes:)` —
//     the config.json PARSE (`KVEstimation`), kept as the pre-load
//     estimate for the memory load gate.
//
// If these ever drift for a production family, load-gate admission and
// engine grants disagree — the exact class of bug the sizing snapshot
// exists to kill. Fixture configs reproduce the REAL production shapes
// (verified against the local checkpoints' config.json); a live variant
// additionally reads the real files when the checkpoints are in the HF
// cache.

import Foundation
import MLXLLM
import MLXLMCommon
import Testing

@testable import ProviderCore

// MARK: - Fixture configs (real production shapes)

/// gpt-oss-20b (mlx-community/gpt-oss-20b-MXFP4-Q8): 24 layers alternating
/// sliding/full, kv_heads 8, head_dim 64, sliding_window 128, context 131k.
private func makeGptossConfigJSON() -> [String: Any] { [
    "model_type": "gpt_oss",
    "num_hidden_layers": 24,
    "num_attention_heads": 64,
    "num_key_value_heads": 8,
    "head_dim": 64,
    "sliding_window": 128,
    "max_position_embeddings": 131_072,
    "layer_types": (0..<24).map { $0 % 2 == 0 ? "sliding_attention" : "full_attention" },
] }

/// gemma-4-26B qat-4bit text_config (mlx-community/gemma-4-26B-A4B-it-qat-4bit):
/// 30 layers (5×sliding + 1×full repeating), kv_heads 8 (sliding),
/// K-eq-V full layers at global_head_dim 512 with 2 global kv heads,
/// sliding head_dim 256, window 1024, no shared-KV block, context 262k.
private func makeGemma4TextConfigJSON() -> [String: Any] { [
    "model_type": "gemma4_text",
    "num_hidden_layers": 30,
    "num_attention_heads": 16,
    "num_key_value_heads": 8,
    "head_dim": 256,
    "global_head_dim": 512,
    "num_global_key_value_heads": 2,
    "num_kv_shared_layers": 0,
    "sliding_window": 1024,
    "attention_k_eq_v": true,
    "max_position_embeddings": 262_144,
    "layer_types": (0..<30).map { $0 % 6 == 5 ? "full_attention" : "sliding_attention" },
] }

/// Write a config dict to a temp model dir and return the dir URL.
private func writeConfigDir(_ config: [String: Any], wrapInTextConfig: Bool = false) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("drift-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var root: [String: Any] = config
    if wrapInTextConfig {
        root = ["model_type": "gemma4", "text_config": config, "vision_config": [:] as [String: Any]]
    }
    let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    try data.write(to: dir.appendingPathComponent("config.json"))
    return dir
}

// MARK: - Kinds derivation from the fixture fields (the model wrappers' inputs)

private func gptossKinds(from config: [String: Any]) -> [CBv2LayerKind] {
    CBv2LayerKindDerivation.gptossLayerKinds(
        layerTypes: config["layer_types"] as? [String],
        numHiddenLayers: config["num_hidden_layers"] as! Int,
        slidingWindow: config["sliding_window"] as! Int,
        headDim: config["head_dim"] as! Int,
        numAttentionHeads: config["num_attention_heads"] as! Int,
        numKeyValueHeads: config["num_key_value_heads"] as! Int)
}

private func gemma4Kinds(from config: [String: Any]) -> [CBv2LayerKind] {
    CBv2LayerKindDerivation.gemma4LayerKinds(
        layerTypes: config["layer_types"] as! [String],
        slidingWindow: config["sliding_window"] as! Int,
        numKvSharedLayers: config["num_kv_shared_layers"] as! Int,
        headDim: config["head_dim"] as! Int,
        globalHeadDim: config["global_head_dim"] as! Int,
        numAttentionHeads: config["num_attention_heads"] as! Int,
        numKeyValueHeads: config["num_key_value_heads"] as! Int,
        numGlobalKeyValueHeads: config["num_global_key_value_heads"] as? Int,
        attentionKeqV: config["attention_k_eq_v"] as! Bool)
}

// MARK: - Tests

@Suite("SlotSizingSnapshot ↔ KVEstimation drift (both prod families)")
struct SlotSizingDriftTests {

    @Test("gpt-oss: cbv2-derived rate == config.json rate (24,576 B/token)")
    func gptossRatesAgree() throws {
        let kinds = gptossKinds(from: makeGptossConfigJSON())
        let engineRate = SlotSizingSnapshot.fp16KVBytesPerToken(layerKinds: kinds)

        let dir = try writeConfigDir(makeGptossConfigJSON())
        defer { try? FileManager.default.removeItem(at: dir) }
        let architecture = KVEstimation.parseModelArchitecture(
            at: dir.appendingPathComponent("config.json"))
        let configRate = BatchScheduler.resolvedKVBytesPerToken(
            architecture: architecture, weightBytes: 12 * 1024 * 1024 * 1024)

        // 12 full layers × 2(K+V) × 8 kvHeads × 64 headDim × 2(fp16).
        #expect(engineRate == 24_576)
        #expect(engineRate == configRate)
    }

    @Test("gemma-4 qat: cbv2-derived rate == config.json rate (20,480 B/token, K-eq-V full layers)")
    func gemma4RatesAgree() throws {
        let kinds = gemma4Kinds(from: makeGemma4TextConfigJSON())
        let engineRate = SlotSizingSnapshot.fp16KVBytesPerToken(layerKinds: kinds)

        // The production checkpoint is a VLM: config.json wraps the text
        // model under text_config — the SAME shape the scanner and the
        // sizing snapshot read.
        let dir = try writeConfigDir(makeGemma4TextConfigJSON(), wrapInTextConfig: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let architecture = KVEstimation.parseModelArchitecture(
            at: dir.appendingPathComponent("config.json"))
        let configRate = BatchScheduler.resolvedKVBytesPerToken(
            architecture: architecture, weightBytes: 15 * 1024 * 1024 * 1024)

        // 5 full layers × 2(K+V) × 2 global kvHeads × 512 globalHeadDim × 2.
        #expect(engineRate == 20_480)
        #expect(engineRate == configRate)
    }

    @Test("estimatedKVBytes mirrors AdmissionV2.estimatedBytes EXACTLY (window plateaus included)")
    func estimatedBytesMatchesEngineLedger() {
        for kinds in [gptossKinds(from: makeGptossConfigJSON()), gemma4Kinds(from: makeGemma4TextConfigJSON())] {
            // The engine's own ledger (fp16 default config) is the oracle.
            let admission = AdmissionV2(layerKinds: kinds, bytesCapacity: Int.max)
            for tokens in [0, 1, 64, 128, 129, 1024, 1025, 4096, 131_072] {
                #expect(
                    SlotSizingSnapshot.estimatedKVBytes(layerKinds: kinds, tokens: tokens)
                        == admission.estimatedBytes(forTokens: tokens),
                    "tokens=\(tokens)")
            }
        }
    }

    @Test("marginal rate == estimatedBytes slope beyond every sliding window")
    func marginalRateIsTheLongContextSlope() {
        for kinds in [gptossKinds(from: makeGptossConfigJSON()), gemma4Kinds(from: makeGemma4TextConfigJSON())] {
            let rate = SlotSizingSnapshot.fp16KVBytesPerToken(layerKinds: kinds)
            // Past the largest window (1024 for gemma, 128 for gpt-oss),
            // each additional token costs exactly the marginal rate.
            let a = SlotSizingSnapshot.estimatedKVBytes(layerKinds: kinds, tokens: 2048)
            let b = SlotSizingSnapshot.estimatedKVBytes(layerKinds: kinds, tokens: 2049)
            #expect(b - a == rate)
        }
    }

    @Test("live drift: REAL checkpoint config.json (skip when not in the HF cache)")
    func liveConfigDrift() throws {
        struct Checkpoint {
            let id: String
            let expectRate: Int
            let textConfigWrapped: Bool
        }
        let checkpoints = [
            Checkpoint(
                id: "mlx-community/gpt-oss-20b-MXFP4-Q8",
                expectRate: 24_576, textConfigWrapped: false),
            Checkpoint(
                id: "mlx-community/gemma-4-26B-A4B-it-qat-4bit",
                expectRate: 20_480, textConfigWrapped: true),
        ]
        for checkpoint in checkpoints {
            guard case .found(let dir) = LiveInferenceFixtures.locate(checkpoint.id) else {
                continue  // skip-if-absent, per live-test policy
            }
            let configURL = dir.appendingPathComponent("config.json")
            let configData = try Data(contentsOf: configURL)

            // Engine truth from the REAL file.
            let engineRate: Int
            if checkpoint.textConfigWrapped {
                let textConfig = try EngineV2VLMTextExtraction.decodeTextConfiguration(
                    configData: configData)
                engineRate = SlotSizingSnapshot.fp16KVBytesPerToken(
                    layerKinds: textConfig.cbv2LayerKinds)
            } else {
                let json = try JSONSerialization.jsonObject(with: configData) as! [String: Any]
                engineRate = SlotSizingSnapshot.fp16KVBytesPerToken(
                    layerKinds: gptossKinds(from: json))
            }

            // Config parse from the SAME real file.
            let architecture = KVEstimation.parseModelArchitecture(at: configURL)
            let configRate = BatchScheduler.resolvedKVBytesPerToken(
                architecture: architecture, weightBytes: 12 * 1024 * 1024 * 1024)

            #expect(engineRate == checkpoint.expectRate, "\(checkpoint.id)")
            #expect(engineRate == configRate, "\(checkpoint.id)")
        }
    }
}
