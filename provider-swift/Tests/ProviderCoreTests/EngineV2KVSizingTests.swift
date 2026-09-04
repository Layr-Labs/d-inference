// Copyright © 2026 Eigen Labs.
//
// Sliding-window RING accounting for the contiguous backend (T3-02): the
// bytes every request allocates up front for its windowed layers, which the
// per-token rate (full layers only) never sees. Pure geometry over the three
// production families plus one REAL `makeProductionBuild` over a tiny
// Gemma-4 config, so the term is pinned where it is consumed
// (`ProductionBuild.fixedRequestBytes`), not only where it is computed.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing

@testable import ProviderCore

private let mib = 1024 * 1024

private func sliding(_ window: Int, kvHeads: Int, headDim: Int, shares: Int? = nil) -> CBv2LayerKind {
    CBv2LayerKind(
        attention: .slidingWindow(window), sharesKVWithLayer: shares,
        headDim: headDim, kvHeads: kvHeads, queryHeads: kvHeads * 2)
}

private func full(kvHeads: Int, headDim: Int, shares: Int? = nil) -> CBv2LayerKind {
    CBv2LayerKind(
        attention: .full, sharesKVWithLayer: shares,
        headDim: headDim, kvHeads: kvHeads, queryHeads: kvHeads * 2)
}

/// The served `mlx-community/gemma-4-26b-a4b-it-{4bit,8bit}` text geometry
/// (config.json: sliding_window 1024, num_key_value_heads 8, head_dim 256,
/// 25 sliding + 5 full layers, num_kv_shared_layers 0; full layers use
/// global_head_dim 512 × 2 KV heads).
private func gemma4_26bLayerKinds() -> [CBv2LayerKind] {
    var kinds: [CBv2LayerKind] = []
    for layer in 0 ..< 30 {
        // Every sixth layer is full attention (sliding_window_pattern 6).
        if layer % 6 == 5 {
            kinds.append(full(kvHeads: 2, headDim: 512))
        } else {
            kinds.append(sliding(1024, kvHeads: 8, headDim: 256))
        }
    }
    return kinds
}

/// gpt-oss-20b: 24 layers alternating sliding(128)/full, 8 KV heads, headDim 64.
private func gptOSS20bLayerKinds() -> [CBv2LayerKind] {
    (0 ..< 24).map { layer in
        layer % 2 == 0 ? sliding(128, kvHeads: 8, headDim: 64) : full(kvHeads: 8, headDim: 64)
    }
}

/// qwen3.6-35b-a3b hybrid trunk: 10 full-attention storage layers, no windows.
private func qwen36LayerKinds() -> [CBv2LayerKind] {
    (0 ..< 10).map { _ in full(kvHeads: 2, headDim: 256) }
}

@Suite("EngineV2KVSizing.contiguousRingBytes")
struct EngineV2KVSizingRingTests {

    @Test("gemma-4-26b: 25 sliding layers × 8 MiB = 200 MiB per request; the rate counts full layers only")
    func gemmaRingsAre200MiB() {
        let kinds = gemma4_26bLayerKinds()
        #expect(kinds.filter { if case .slidingWindow = $0.attention { return true }; return false }.count == 25)
        #expect(EngineV2KVSizing.contiguousRingBytes(layerKinds: kinds, kvDTypeSize: 2) == 209_715_200)
        #expect(EngineV2KVSizing.contiguousRingBytes(layerKinds: kinds, kvDTypeSize: 2) == 25 * 8 * mib)
        // The marginal per-token rate is the full layers alone (20 KiB/token)
        // — the 200 MiB above is invisible to it, which is the defect.
        #expect(SlotSizingSnapshot.fp16KVBytesPerToken(layerKinds: kinds) == 20_480)
    }

    @Test("gpt-oss-20b: 12 × 256 KiB = 3 MiB; qwen3.6 (no windows) = 0")
    func otherFamilies() {
        #expect(EngineV2KVSizing.contiguousRingBytes(layerKinds: gptOSS20bLayerKinds(), kvDTypeSize: 2) == 3 * mib)
        #expect(EngineV2KVSizing.contiguousRingBytes(layerKinds: qwen36LayerKinds(), kvDTypeSize: 2) == 0)
        #expect(EngineV2KVSizing.contiguousRingBytes(layerKinds: [], kvDTypeSize: 2) == 0)
    }

    @Test("KV-shared sliding layers own no ring; the dtype width scales the ring; degenerate inputs are zero")
    func sharingDTypeAndDegenerates() {
        // Gemma-style sharing: the last four sliding layers borrow K/V from
        // earlier ones and allocate nothing.
        var shared = gemma4_26bLayerKinds()
        shared[28] = sliding(1024, kvHeads: 8, headDim: 256, shares: 22)
        shared[27] = sliding(1024, kvHeads: 8, headDim: 256, shares: 21)
        #expect(EngineV2KVSizing.contiguousRingBytes(layerKinds: shared, kvDTypeSize: 2) == 23 * 8 * mib)
        // fp32 rings would be twice as large; the caller passes the backend's
        // ACTUAL kv dtype, never an assumed 2.
        #expect(EngineV2KVSizing.contiguousRingBytes(layerKinds: gptOSS20bLayerKinds(), kvDTypeSize: 4) == 6 * mib)
        #expect(EngineV2KVSizing.contiguousRingBytes(layerKinds: gptOSS20bLayerKinds(), kvDTypeSize: 0) == 0)
        #expect(EngineV2KVSizing.contiguousRingBytes(layerKinds: [sliding(0, kvHeads: 8, headDim: 64)], kvDTypeSize: 2) == 0)
        // Saturates rather than trapping on absurd geometry.
        let huge = [sliding(Int.max / 2, kvHeads: Int.max / 2, headDim: 4)]
        #expect(EngineV2KVSizing.contiguousRingBytes(layerKinds: huge, kvDTypeSize: 2) == Int.max)
    }
}

// MARK: - Real build: the term lands on ProductionBuild.fixedRequestBytes

private func decodeConfig<T: Decodable>(_ json: [String: Any]) throws -> T {
    let data = try JSONSerialization.data(withJSONObject: json)
    return try JSONDecoder().decode(T.self, from: data)
}

/// 2-layer Gemma-4 text: [sliding(16), full], no KV sharing, headDim 64,
/// 2 KV heads — one ring of 16 × 2 × 64 × 2 × 2 = 8 KiB.
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

private let ringTestCapacity = 8 << 20
private let hermeticGuardEnvironment = [KVBackendGuardStore.pathEnvKey: "/dev/null"]

@Suite("ProductionBuild.fixedRequestBytes charges contiguous rings")
struct EngineV2RingChargeBuildTests {

    @Test("contiguous gemma build: fixedRequestBytes = recurrent (0) + rings; paged build stays 0")
    func contiguousChargesRingsPagedDoesNot() async throws {
        _ = LiveInferenceFixtures.ensureMetallibColocated()
        let model = try tinyGemma4Text()
        let expectedRing = 16 * 2 * 64 * 2 * 2
        #expect(EngineV2KVSizing.contiguousRingBytes(layerKinds: model.cbv2LayerKinds, kvDTypeSize: 2) == expectedRing)

        let contiguous = try EngineV2Factory.makeProductionBuild(
            model: model,
            tokenizer: StubBridgeTokenizer(),
            kvBytesCapacity: ringTestCapacity,
            maxConcurrentRequests: 2,
            kvBackend: .contiguous,
            maxContextLength: 2048,
            environment: hermeticGuardEnvironment)
        #expect(contiguous.kvBackendKind == .contiguous)
        // Attention-only model: the engine's own fixed term is the recurrent
        // state (0), so the whole figure is the ring.
        let engine = try #require(contiguous.engine as? EngineV2)
        #expect(engine.resolvedFixedBytesPerRequest == 0)
        #expect(contiguous.fixedRequestBytes == expectedRing)
        await contiguous.engine.shutdown()

        // Paged rows are charged per page (`PagedKVPool.pageDemand`), never a
        // whole ring — the paged bridge keeps the engine's term unchanged.
        let paged = try EngineV2Factory.makeProductionBuild(
            model: model,
            tokenizer: StubBridgeTokenizer(),
            kvBytesCapacity: ringTestCapacity,
            maxConcurrentRequests: 2,
            kvBackend: .paged,
            maxContextLength: 2048,
            environment: hermeticGuardEnvironment,
            pagedPreflightOverride: { _ in })
        #expect(paged.kvBackendKind == .paged)
        #expect(paged.fixedRequestBytes == 0)
        await paged.engine.shutdown()
    }
}
