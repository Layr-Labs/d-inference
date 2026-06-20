// Copyright © 2026 Eigen Labs.
//
// Deterministic unit tests for the DAR-317/DAR-318 KV-quant engine wiring
// and byte accounting. These avoid loading a real model; they exercise the
// pure factory-selection helper and the KV-byte math directly.

import Foundation
import Darwin
import MLX
@testable import MLXLMCommon
@testable import ProviderCore
import Testing

// `.serialized`: several tests mutate the process-wide DARKBLOOM_KV_GPTOSS_KERNEL
// env var (set/unset) to exercise the GPT-OSS kernel override. Swift Testing runs
// tests in parallel by default, so without serialization these would race and
// observe each other's environment state nondeterministically.
@Suite("KV-quant engine wiring + byte accounting", .serialized)
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

    /// GPT-OSS-like hybrid config: 4 cached layers, 2 sliding + 2 full.
    /// No separate global dims; full layers use the same `head_dim` as sliding.
    private typealias GPTOSSLikeConfig = (
        numLayers: Int,
        kvHeads: Int,
        headDim: Int,
        numKvSharedLayers: Int,
        globalHeadDim: Int?,
        numGlobalKvHeads: Int?,
        slidingWindowPattern: Int?,
        layerTypes: [String]?
    )
    private let gptOSSLike: GPTOSSLikeConfig = (
        numLayers: 4,
        kvHeads: 8,
        headDim: 64,
        numKvSharedLayers: 0,
        globalHeadDim: nil,
        numGlobalKvHeads: nil,
        slidingWindowPattern: nil,
        layerTypes: [
            "sliding_attention",
            "full_attention",
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

        // Pattern [S,S,S,F] over 4 cached layers => one full layer.
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

    @Test("computeKVBytesPerToken reduces GPT-OSS full layers with K8V8 g64")
    func byteAccountingReducesForGPTOSSWithK8V8G64() {
        let fp16Bytes = KVEstimation.computeKVBytesPerToken(
            numLayers: gptOSSLike.numLayers,
            kvHeads: gptOSSLike.kvHeads,
            headDim: gptOSSLike.headDim,
            numKvSharedLayers: gptOSSLike.numKvSharedLayers,
            globalHeadDim: gptOSSLike.globalHeadDim,
            numGlobalKvHeads: gptOSSLike.numGlobalKvHeads,
            slidingWindowPattern: gptOSSLike.slidingWindowPattern,
            layerTypes: gptOSSLike.layerTypes,
            quantScheme: nil
        )
        let quantBytes = KVEstimation.computeKVBytesPerToken(
            numLayers: gptOSSLike.numLayers,
            kvHeads: gptOSSLike.kvHeads,
            headDim: gptOSSLike.headDim,
            numKvSharedLayers: gptOSSLike.numKvSharedLayers,
            globalHeadDim: gptOSSLike.globalHeadDim,
            numGlobalKvHeads: gptOSSLike.numGlobalKvHeads,
            slidingWindowPattern: gptOSSLike.slidingWindowPattern,
            layerTypes: gptOSSLike.layerTypes,
            quantScheme: .gptOSSK8V8G64
        )

        let expectedRatio = KVQuantCandidateMode.k8v8g64Dequant.effectiveKVBytesPerTokenPerElem / 4.0
        let expected = Int((Double(fp16Bytes) * expectedRatio).rounded())

        #expect(quantBytes == expected,
            "quantized full-attention bytes must match the K8V8 g64 effective ratio")
        #expect(Double(fp16Bytes) / Double(quantBytes) > 1.8,
            "capacity gain must be close to 2x for K8V8 g64")
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

    @Test("factory on kernel kind: full layers use QuantizedBatchKVCache, sliding uses QuantizedBatchRotatingKVCache")
    func factoryOnKernelKindUsesQuantizedBatchKVCache() {
        let quantConfig = KVQuantizationConfig(groupSize: 128, bits: 8, mode: .affine, cacheKind: .kernel)
        let fullName = Scheduler.cacheFactoryTypeName(
            for: KVCacheSimple(), quantConfig: quantConfig)
        let slidingName = Scheduler.cacheFactoryTypeName(
            for: RotatingKVCache(maxSize: 1024, keep: 0, step: 1024),
            quantConfig: quantConfig)

        #expect(fullName == "QuantizedBatchKVCache",
            "full-attention layer must use QuantizedBatchKVCache when quant kind is kernel")
        // Sliding-window layers are quantized too (#46): the quant groups run along
        // head-dim, so the rotating-window front-trim stays group-aligned.
        #expect(slidingName == "QuantizedBatchRotatingKVCache",
            "sliding-window layer must use QuantizedBatchRotatingKVCache when quant kind is kernel")
    }

    @Test("factory on dequant kind: full layers use DequantBatchKVCache, sliding uses DequantBatchRotatingKVCache")
    func factoryOnDequantKindUsesDequantBatchKVCache() {
        let quantConfig = KVQuantizationConfig(groupSize: 64, bits: 8, mode: .affine, cacheKind: .dequant)
        let fullName = Scheduler.cacheFactoryTypeName(
            for: KVCacheSimple(), quantConfig: quantConfig)
        let slidingName = Scheduler.cacheFactoryTypeName(
            for: RotatingKVCache(maxSize: 1024, keep: 0, step: 1024),
            quantConfig: quantConfig)

        #expect(fullName == "DequantBatchKVCache",
            "full-attention layer must use DequantBatchKVCache when quant kind is dequant")
        // Sliding-window layers are quantized too (#46).
        #expect(slidingName == "DequantBatchRotatingKVCache",
            "sliding-window layer must use DequantBatchRotatingKVCache when quant kind is dequant")
    }

    @Test("factory ignores quant config for arrays and mamba-style caches")
    func factoryIgnoresQuantForNonAttentionCaches() {
        let quantConfig = KVQuantizationConfig(groupSize: 128, bits: 8, mode: .affine, cacheKind: .kernel)

        // ArraysCache is used by recurrent/SSM-style layers.
        let arraysName = Scheduler.cacheFactoryTypeName(
            for: ArraysCache(size: 4), quantConfig: quantConfig)
        #expect(arraysName == "ArraysCache",
            "ArraysCache layers must not be replaced by quantized caches")
    }

    // MARK: - KVQuantPolicy gating

    @Test("KVQuantPolicy classifies Gemma 4 and GPT-OSS as supported families")
    func policyClassifiesSupportedFamilies() {
        #expect(KVQuantPolicy.classify(modelID: "mlx-community/gemma-4-4b-it") == .gemma4)
        #expect(KVQuantPolicy.classify(modelID: "google/gemma-4-9b-it") == .gemma4)
        #expect(KVQuantPolicy.classify(modelID: "openai/gpt-oss-20b") == .gptOSS)
        #expect(KVQuantPolicy.classify(modelID: "mlx-community/Llama-3.1-8B") == .unknown)
    }

    // MARK: - Family-specific scheme selection (DAR-322)

    @Test("Gemma 4 resolves to kernel cache scheme K8V8 g128")
    func gemma4ResolvesToKernelScheme() {
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

        let scheme = BatchScheduler.resolveKVQuantScheme(
            modelID: "gemma-4-26b-it",
            architecture: architecture,
            kvQuantEnabled: true
        )

        #expect(scheme == .gemma4K8V8G128)
        #expect(scheme?.schedulerConfig.cacheKind == .kernel)
        #expect(scheme?.schedulerConfig.groupSize == 128)
    }

    @Test("GPT-OSS resolves to dequant cache scheme K8V8 g64")
    func gptOSSResolvesToDequantScheme() {
        unsetenv("DARKBLOOM_KV_GPTOSS_KERNEL")
        let architecture = ModelArchitecture(
            numLayers: gptOSSLike.numLayers,
            kvHeads: gptOSSLike.kvHeads,
            headDim: gptOSSLike.headDim,
            numKvSharedLayers: gptOSSLike.numKvSharedLayers,
            globalHeadDim: gptOSSLike.globalHeadDim,
            numGlobalKvHeads: gptOSSLike.numGlobalKvHeads,
            slidingWindowPattern: gptOSSLike.slidingWindowPattern,
            layerTypes: gptOSSLike.layerTypes,
            maxContextLength: 8192
        )

        let scheme = BatchScheduler.resolveKVQuantScheme(
            modelID: "openai/gpt-oss-20b",
            architecture: architecture,
            kvQuantEnabled: true
        )

        #expect(scheme == .gptOSSK8V8G64)
        #expect(scheme?.schedulerConfig.cacheKind == .dequant)
        #expect(scheme?.schedulerConfig.groupSize == 64)
    }

    @Test("GPT-OSS env override resolves to kernel cache scheme K8V8 g64")
    func gptOSSKernelOverrideResolvesToKernelScheme() {
        setenv("DARKBLOOM_KV_GPTOSS_KERNEL", "1", 1)
        defer { unsetenv("DARKBLOOM_KV_GPTOSS_KERNEL") }
        let architecture = ModelArchitecture(
            numLayers: gptOSSLike.numLayers,
            kvHeads: gptOSSLike.kvHeads,
            headDim: gptOSSLike.headDim,
            numKvSharedLayers: gptOSSLike.numKvSharedLayers,
            globalHeadDim: gptOSSLike.globalHeadDim,
            numGlobalKvHeads: gptOSSLike.numGlobalKvHeads,
            slidingWindowPattern: gptOSSLike.slidingWindowPattern,
            layerTypes: gptOSSLike.layerTypes,
            maxContextLength: 8192
        )

        let scheme = BatchScheduler.resolveKVQuantScheme(
            modelID: "openai/gpt-oss-20b",
            architecture: architecture,
            kvQuantEnabled: true
        )

        #expect(scheme?.candidateMode == .k8v8g64)
        #expect(scheme?.schedulerConfig.cacheKind == .kernel)
        #expect(scheme?.schedulerConfig.groupSize == 64)
    }

    @Test("GPT-OSS scheme is rejected when head_dim cannot accommodate g64")
    func gptOSSSchemeRejectsIncompatibleHeadDim() {
        let badArchitecture = ModelArchitecture(
            numLayers: gptOSSLike.numLayers,
            kvHeads: gptOSSLike.kvHeads,
            headDim: 32,  // smaller than the required group size 64
            numKvSharedLayers: gptOSSLike.numKvSharedLayers,
            globalHeadDim: gptOSSLike.globalHeadDim,
            numGlobalKvHeads: gptOSSLike.numGlobalKvHeads,
            slidingWindowPattern: gptOSSLike.slidingWindowPattern,
            layerTypes: gptOSSLike.layerTypes,
            maxContextLength: 8192
        )

        let scheme = BatchScheduler.resolveKVQuantScheme(
            modelID: "openai/gpt-oss-20b",
            architecture: badArchitecture,
            kvQuantEnabled: true
        )

        #expect(scheme == nil,
            "GPT-OSS must not select a quant scheme when head_dim is too small for g64")
    }

    @Test("Gemma 4 scheme is rejected when the quantized layer dim is not divisible by 128")
    func gemma4SchemeRejectsIncompatibleHeadDim() {
        // global_head_dim 100 is not a multiple of the g128 group size; enabling
        // the kernel would trap the quantized cache precondition at decode.
        let badArchitecture = ModelArchitecture(
            numLayers: gemmaLike.numLayers,
            kvHeads: gemmaLike.kvHeads,
            headDim: gemmaLike.headDim,
            numKvSharedLayers: gemmaLike.numKvSharedLayers,
            globalHeadDim: 100,
            numGlobalKvHeads: gemmaLike.numGlobalKvHeads,
            slidingWindowPattern: gemmaLike.slidingWindowPattern,
            layerTypes: gemmaLike.layerTypes,
            maxContextLength: 8192
        )

        let scheme = BatchScheduler.resolveKVQuantScheme(
            modelID: "gemma-4-26b-it",
            architecture: badArchitecture,
            kvQuantEnabled: true
        )

        #expect(scheme == nil,
            "Gemma 4 must not select g128 when the quantized layer dim is not divisible by 128")
    }

    @Test("Gemma 4 scheme is rejected when architecture has no usable head_dim")
    func gemma4SchemeRejectsMissingHeadDim() {
        let emptyDims = ModelArchitecture(
            numLayers: gemmaLike.numLayers,
            kvHeads: gemmaLike.kvHeads,
            headDim: nil,
            numKvSharedLayers: gemmaLike.numKvSharedLayers,
            globalHeadDim: nil,
            numGlobalKvHeads: gemmaLike.numGlobalKvHeads,
            slidingWindowPattern: gemmaLike.slidingWindowPattern,
            layerTypes: gemmaLike.layerTypes,
            maxContextLength: 8192
        )

        let scheme = BatchScheduler.resolveKVQuantScheme(
            modelID: "gemma-4-26b-it",
            architecture: emptyDims,
            kvQuantEnabled: true
        )

        #expect(scheme == nil,
            "Gemma 4 must not enable KV quant when no head_dim could be parsed")
    }

    @Test("Gemma 4 falls back to head_dim when no global dim is declared")
    func gemma4UsesHeadDimWhenNoGlobalDim() {
        // No global_head_dim; head_dim 256 is divisible by 128 → scheme resolves.
        let architecture = ModelArchitecture(
            numLayers: gemmaLike.numLayers,
            kvHeads: gemmaLike.kvHeads,
            headDim: 256,
            numKvSharedLayers: gemmaLike.numKvSharedLayers,
            globalHeadDim: nil,
            numGlobalKvHeads: nil,
            slidingWindowPattern: gemmaLike.slidingWindowPattern,
            layerTypes: gemmaLike.layerTypes,
            maxContextLength: 8192
        )

        let scheme = BatchScheduler.resolveKVQuantScheme(
            modelID: "gemma-4-26b-it",
            architecture: architecture,
            kvQuantEnabled: true
        )

        #expect(scheme == .gemma4K8V8G128)
    }
}
