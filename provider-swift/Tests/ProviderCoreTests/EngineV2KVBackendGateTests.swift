// Copyright © 2026 Eigen Labs.
//
// KV-backend GATE tests over the REAL `EngineV2Factory.makeProductionBuild`
// with tiny real-family models (JSON-decoded configs, random-init weights,
// no downloads): production-safe `auto` (always contiguous), the fleet
// kill switch at the deepest layer, explicit
// selections, and the eligibility fallback (ineligible head dim → paged
// selection degrades to contiguous, never a refusal).
//
// These tests CONSTRUCT engines (paged construction materializes its slab
// pool — a small Metal eval), but never run a forward pass.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing

@testable import ProviderCore

// MARK: - Tiny real-family fixtures

private func decodeConfig<T: Decodable>(_ json: [String: Any]) throws -> T {
    let data = try JSONSerialization.data(withJSONObject: json)
    return try JSONDecoder().decode(T.self, from: data)
}

/// 2-layer GPT-OSS: alternating sliding/full derivation, sinks on every
/// layer, headDim 64 / GQA 2 — the paged kernel's validated shape family.
private func tinyGPTOSS(headDim: Int = 64) throws -> GPTOSSModel {
    let config: GPTOSSConfiguration = try decodeConfig([
        "model_type": "gpt_oss",
        "num_hidden_layers": 2,
        "num_local_experts": 4,
        "num_experts_per_tok": 2,
        "vocab_size": 128,
        "rms_norm_eps": 1e-5,
        "hidden_size": 64,
        "intermediate_size": 64,
        "head_dim": headDim,
        "num_attention_heads": 4,
        "num_key_value_heads": 2,
        "sliding_window": 32,
    ])
    return GPTOSSModel(config)
}

/// 2-layer Gemma-4 text: [sliding(16), full], no KV sharing, headDim 64.
private func tinyGemma4Text() throws -> Gemma4TextModel {
    let config: Gemma4TextConfiguration = try decodeConfig([
        "model_type": "gemma4_text",
        "hidden_size": 64,
        "num_hidden_layers": 2,
        "intermediate_size": 128,
        "num_attention_heads": 4,
        "head_dim": 64,
        "global_head_dim": 64,
        "vocab_size": 128,
        "vocab_size_per_layer_input": 128,
        "num_key_value_heads": 2,
        "num_kv_shared_layers": 0,
        "hidden_size_per_layer_input": 32,
        "sliding_window": 16,
        "sliding_window_pattern": 2,
        "max_position_embeddings": 2048,
        "use_double_wide_mlp": false,
    ])
    return Gemma4TextModel(config)
}

private let gateTestCapacity = 8 << 20  // 8 MiB pool — tiny but constructible

private func makeBuild(
    model: any LanguageModel,
    kvBackend: EngineV2KVBackendSelection,
    environment: [String: String] = [:],
    pagedResourceSearchRoots: [URL]? = nil
) throws -> EngineV2Factory.ProductionBuild {
    _ = LiveInferenceFixtures.ensureMetallibColocated()
    return try EngineV2Factory.makeProductionBuild(
        model: model,
        tokenizer: StubBridgeTokenizer(),
        kvBytesCapacity: gateTestCapacity,
        prefixCache: nil,
        maxConcurrentRequests: 2,
        kvBackend: kvBackend,
        maxContextLength: 2048,
        environment: environment,
        pagedResourceSearchRoots: pagedResourceSearchRoots)
}

// MARK: - Tests

@Suite("EngineV2 KV-backend gate (real tiny models)", .serialized)
struct EngineV2KVBackendGateTests {
    init() {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
    }

    @Test("auto is contiguous for GPT-OSS and cannot drift with family defaults")
    func autoServesContiguousForGPTOSS() async throws {
        let build = try makeBuild(model: try tinyGPTOSS(), kvBackend: .auto)
        #expect(build.kvBackendKind == .contiguous)
        #expect(build.kvBackendFallbackReason == nil)
        let snapshot = build.engine.capacity()
        #expect(snapshot.kvBytesBackendCapacity == gateTestCapacity)
        await build.engine.shutdown()
    }

    @Test("auto resolves contiguous for Gemma-4 (bf16 KV stays opt-in)")
    func autoServesContiguousForGemma() async throws {
        let build = try makeBuild(model: try tinyGemma4Text(), kvBackend: .auto)
        #expect(build.kvBackendKind == .contiguous)
        #expect(build.kvBackendFallbackReason == nil)
        await build.engine.shutdown()
    }

    @Test("explicit contiguous wins over the GPT-OSS auto default")
    func explicitContiguous() async throws {
        let build = try makeBuild(model: try tinyGPTOSS(), kvBackend: .contiguous)
        #expect(build.kvBackendKind == .contiguous)
        #expect(build.kvBackendFallbackReason == nil)
        await build.engine.shutdown()
    }

    @Test("explicit paged GPT-OSS preflights packaged resources and physical pool truth")
    func explicitPagedGPTOSS() async throws {
        try PagedAttentionKernel.validateRuntimeResources()
        let build = try makeBuild(model: try tinyGPTOSS(), kvBackend: .paged)
        #expect(build.kvBackendKind == .paged)
        #expect(build.kvBackendFallbackReason == nil)
        let snapshot = build.engine.capacity()
        #expect(snapshot.kvBytesCapacity > 0)
        #expect(snapshot.kvBytesCapacity == snapshot.kvBytesBackendCapacity)
        #expect(snapshot.kvBytesCapacity < gateTestCapacity)
        await build.engine.shutdown()
    }

    @Test("explicit paged serves Gemma-4 TEXT (eligible shapes, opt-in)")
    func explicitPagedGemmaText() async throws {
        let build = try makeBuild(model: try tinyGemma4Text(), kvBackend: .paged)
        #expect(build.kvBackendKind == .paged)
        #expect(build.kvBackendFallbackReason == nil)
        await build.engine.shutdown()
    }

    @Test("fleet kill switch forces explicit paged to contiguous at the deepest layer")
    func killSwitchForcesContiguous() async throws {
        let build = try makeBuild(
            model: try tinyGPTOSS(),
            kvBackend: .paged,
            environment: [EngineV2KVBackendPolicy.killSwitchEnvKey: "0"])
        #expect(build.kvBackendKind == .contiguous)
        #expect(build.kvBackendFallbackReason == "kill_switch")
        await build.engine.shutdown()
    }

    @Test("kernel-ineligible shape falls back to contiguous, never refuses")
    func ineligibleFallsBack() async throws {
        // headDim 80 is outside the paged kernel's {64,128,256,512}.
        let build = try makeBuild(model: try tinyGPTOSS(headDim: 80), kvBackend: .paged)
        #expect(build.kvBackendKind == .contiguous)
        #expect(build.kvBackendFallbackReason?.hasPrefix("ineligible:") == true)
        await build.engine.shutdown()
    }

    @Test("missing packaged resource falls back to contiguous before any request")
    func missingResourceFallsBack() async throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("paged-gate-missing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        let build = try makeBuild(
            model: try tinyGPTOSS(),
            kvBackend: .paged,
            pagedResourceSearchRoots: [empty])
        #expect(build.kvBackendKind == .contiguous)
        #expect(build.kvBackendFallbackReason?.contains("runtime resource unavailable") == true)
        await build.engine.shutdown()
    }
}
