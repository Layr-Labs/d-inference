// Copyright © 2026 Eigen Labs.
//
// Deterministic unit tests for the DAR-317/DAR-318 KV-quant engine wiring
// and byte accounting. These avoid loading a real model; they exercise the
// pure factory-selection helper and the KV-byte math directly.

import Foundation
import MLX
@testable import MLXLMCommon
@testable import ProviderCore
import Testing

@Suite("KV-quant engine wiring + byte accounting")
struct KVQuantEngineTests {

    // MARK: - Byte accounting (DAR-318)

    /// Gemma-like hybrid config: 4 cached layers, 3 sliding + 1 full.
    /// Full layers use global heads/dim; sliding layers use local heads/dim.
    private typealias GemmaLikeConfig = (
        numLayers: Int,
        kvHeads: Int,
        headDim: Int,
        numKvSharedLayers: Int,
        globalHeadDim: Int?,
        numGlobalKvHeads: Int?,
        slidingWindowPattern: Int?,
        layerTypes: [String]?
    )
    private let gemmaLike: GemmaLikeConfig = (
        numLayers: 4,
        kvHeads: 8,
        headDim: 256,
        numKvSharedLayers: 0,
        globalHeadDim: 512,
        numGlobalKvHeads: 2,
        slidingWindowPattern: nil,
        layerTypes: [
            "sliding_attention",
            "sliding_attention",
            "sliding_attention",
            "full_attention",
        ]
    )

    @Test("computeKVBytesPerToken unchanged when quant scheme is nil")
    func byteAccountingUnchangedWhenDisabled() {
        let bytes = KVEstimation.computeKVBytesPerToken(
            numLayers: gemmaLike.numLayers,
            kvHeads: gemmaLike.kvHeads,
            headDim: gemmaLike.headDim,
            numKvSharedLayers: gemmaLike.numKvSharedLayers,
            globalHeadDim: gemmaLike.globalHeadDim,
            numGlobalKvHeads: gemmaLike.numGlobalKvHeads,
            slidingWindowPattern: gemmaLike.slidingWindowPattern,
            layerTypes: gemmaLike.layerTypes,
            quantScheme: nil
        )

        // Pattern [S,S,S,S,F] over 4 cached layers => one full layer.
        // Full layer uses global dims: 2 heads * 512 dim * 2 tensors * 2 bytes = 4096.
        #expect(bytes == 4096, "fp16 path must remain unchanged when quant scheme is nil")
    }

    @Test("computeKVBytesPerToken roughly halves for Gemma-like config with K8V8")
    func byteAccountingHalvesForGemmaWithK8V8() {
        let fp16Bytes = KVEstimation.computeKVBytesPerToken(
            numLayers: gemmaLike.numLayers,
            kvHeads: gemmaLike.kvHeads,
            headDim: gemmaLike.headDim,
            numKvSharedLayers: gemmaLike.numKvSharedLayers,
            globalHeadDim: gemmaLike.globalHeadDim,
            numGlobalKvHeads: gemmaLike.numGlobalKvHeads,
            slidingWindowPattern: gemmaLike.slidingWindowPattern,
            layerTypes: gemmaLike.layerTypes,
            quantScheme: nil
        )
        let quantBytes = KVEstimation.computeKVBytesPerToken(
            numLayers: gemmaLike.numLayers,
            kvHeads: gemmaLike.kvHeads,
            headDim: gemmaLike.headDim,
            numKvSharedLayers: gemmaLike.numKvSharedLayers,
            globalHeadDim: gemmaLike.globalHeadDim,
            numGlobalKvHeads: gemmaLike.numGlobalKvHeads,
            slidingWindowPattern: gemmaLike.slidingWindowPattern,
            layerTypes: gemmaLike.layerTypes,
            quantScheme: .gemma4K8V8G128
        )

        let expectedRatio = KVQuantCandidateMode.k8v8g128.effectiveKVBytesPerTokenPerElem / 4.0
        let expected = Int((Double(fp16Bytes) * expectedRatio).rounded())

        #expect(quantBytes == expected,
            "quantized full-attention bytes must match the K8V8 effective ratio")
        #expect(Double(quantBytes) < Double(fp16Bytes) * 0.55,
            "quantized bytes must be materially smaller than fp16 (~half)")
        #expect(Double(quantBytes) > Double(fp16Bytes) * 0.45,
            "quantized bytes must not be pathologically small")
    }

    @Test("resolvedKVBytesPerToken scales down and dynamic budget doubles")
    func resolvedKVBytesAndBudgetScaleDown() {
        let architecture = ModelArchitecture(
            numLayers: gemmaLike.numLayers,
            kvHeads: gemmaLike.kvHeads,
            headDim: gemmaLike.headDim,
            numKvSharedLayers: gemmaLike.numKvSharedLayers,
            globalHeadDim: gemmaLike.globalHeadDim,
            numGlobalKvHeads: gemmaLike.numGlobalKvHeads,
            slidingWindowPattern: gemmaLike.slidingWindowPattern,
            layerTypes: gemmaLike.layerTypes,
            maxContextLength: 8192
        )

        let fp16 = BatchScheduler.resolvedKVBytesPerToken(
            architecture: architecture, weightBytes: 10_000_000, quantScheme: nil)
        let quant = BatchScheduler.resolvedKVBytesPerToken(
            architecture: architecture, weightBytes: 10_000_000, quantScheme: .gemma4K8V8G128)

        #expect(quant < fp16, "quantized kvBytesPerToken must be smaller than fp16")
        #expect(Double(fp16) / Double(quant) > 1.8,
            "capacity gain must be close to 2x for K8V8")
    }

    // MARK: - Cache factory selection (DAR-317)

    @Test("factory off: full layers use BatchKVCache, sliding layers use BatchRotatingKVCache")
    func factoryOffUsesFp16Caches() {
        let fullName = Scheduler.cacheFactoryTypeName(
            for: KVCacheSimple(), quantConfig: nil)
        let slidingName = Scheduler.cacheFactoryTypeName(
            for: RotatingKVCache(maxSize: 1024, keep: 0, step: 1024),
            quantConfig: nil)

        #expect(fullName == "BatchKVCache",
            "full-attention layer must use BatchKVCache when quant is off")
        #expect(slidingName == "BatchRotatingKVCache",
            "sliding-attention layer must use BatchRotatingKVCache")
    }

    @Test("factory on: full layers use QuantizedBatchKVCache, sliding stays BatchRotatingKVCache")
    func factoryOnUsesQuantizedFullAndFp16Sliding() {
        let quantConfig = KVQuantizationConfig(groupSize: 128, bits: 8, mode: .affine)
        let fullName = Scheduler.cacheFactoryTypeName(
            for: KVCacheSimple(), quantConfig: quantConfig)
        let slidingName = Scheduler.cacheFactoryTypeName(
            for: RotatingKVCache(maxSize: 1024, keep: 0, step: 1024),
            quantConfig: quantConfig)

        #expect(fullName == "QuantizedBatchKVCache",
            "full-attention layer must use QuantizedBatchKVCache when quant is on")
        #expect(slidingName == "BatchRotatingKVCache",
            "sliding-attention layer must stay fp16 (BatchRotatingKVCache)")
    }

    @Test("factory ignores quant config for arrays and mamba-style caches")
    func factoryIgnoresQuantForNonAttentionCaches() {
        let quantConfig = KVQuantizationConfig(groupSize: 128, bits: 8, mode: .affine)

        // ArraysCache is used by recurrent/SSM-style layers.
        let arraysName = Scheduler.cacheFactoryTypeName(
            for: ArraysCache(size: 4), quantConfig: quantConfig)
        #expect(arraysName == "ArraysCache",
            "ArraysCache layers must not be replaced by quantized caches")
    }

    // MARK: - KVQuantPolicy gating

    @Test("KVQuantPolicy classifies Gemma 4 and excludes GPT-OSS for v1")
    func policyGatesGemma4Only() {
        #expect(KVQuantPolicy.classify(modelID: "mlx-community/gemma-4-4b-it") == .gemma4)
        #expect(KVQuantPolicy.classify(modelID: "google/gemma-4-9b-it") == .gemma4)
        #expect(KVQuantPolicy.classify(modelID: "openai/gpt-oss-20b") == .gptOSS)
        #expect(KVQuantPolicy.classify(modelID: "mlx-community/Llama-3.1-8B") == .unknown)
    }
}
