//
//  Gemma4Text.swift
//  mlx-swift-lm
//
//  Port of https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/models/gemma4_text.py

import Foundation
import MLX
import MLXLMCommon
import MLXNN

// MARK: - vMLX decode hot-path helpers (ported from osaurus/main Gemma4Text)
//
// File-private, self-contained compiled fusions. They do NOT depend on the
// SwitchLayers / HardwareInfo lane so this file builds stand-alone; when that
// lane lands public `safeGeluApproximate` / `MLXHardwareInfo` these can collapse
// to the shared symbols (identical math + same env knob) with no behavior change.
// `compile(shapeless: true)` is gated by `MLX_COMPILED_DECODE` (default on),
// mirroring `MLXHardwareInfo.isCompiledDecodeSupported`, so M1/M2 + macOS Tahoe
// (MLX #3329) can opt out without a code change. Matches the ungated
// `compiledSiluProduct` / `weightedExpertSum` convention already in this tree.
private let gemma4CompiledDecodeSupported: Bool = {
    if let raw = ProcessInfo.processInfo.environment["MLX_COMPILED_DECODE"] {
        return ["1", "true", "yes", "on"].contains(raw.lowercased())
    }
    return true
}()

// MARK: - CBv2 prompt-path knobs (prefill only; decode never reads these)

@inline(__always)
private func gemma4TruthyFlag(_ raw: String?) -> Bool {
    guard let raw else { return false }
    return ["1", "true", "yes", "on"].contains(raw.lowercased())
}

/// Submit intermediate Gemma 4 prefill graphs while Swift continues to build
/// later layers. This changes only when already-built work is queued; the
/// operations and results are unchanged. Single-token decode is excluded.
///
/// The 18-layer default leaves twelve layers of the 30-layer 26B model for
/// useful CPU/GPU overlap. `DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL=0` restores
/// one final submission; another positive value tunes the layer interval.
@inline(__always)
internal func resolveGemma4PrefillChunkEvalLayers(_ raw: String?) -> Int {
    guard let raw, let value = Int(raw) else { return 18 }
    return max(0, value)
}

internal let gemma4PrefillChunkEvalLayers = resolveGemma4PrefillChunkEvalLayers(
    ProcessInfo.processInfo.environment["DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL"])

@inline(__always)
internal func gemma4ShouldSubmitPrefillChunkEval(
    schedulePrefill: Bool,
    isCBv2: Bool,
    inputLength: Int,
    layerNumber: Int,
    interval: Int
) -> Bool {
    schedulePrefill && isCBv2 && interval > 0 && inputLength > 1
        && layerNumber.isMultiple(of: interval)
}

/// CBv2 consumes only the final prompt position, so the LAST decoder layer
/// can keep full attention and every K/V write while retaining just this
/// many trailing rows for `o_proj`, the residual, the feed-forward/MoE
/// branches, PLE, and the final norm. One row is what the frontier needs,
/// and it puts that work on the same small-M expert path as B=1 decode.
///
/// `DARKBLOOM_GEMMA4_PREFILL_TAIL_ROWS=0` restores the full final layer
/// (the kill switch); a larger value is for comparing kernel geometries.
internal let gemma4PrefillTailRows: Int = {
    guard let raw = ProcessInfo.processInfo.environment[
        "DARKBLOOM_GEMMA4_PREFILL_TAIL_ROWS"],
        let value = Int(raw)
    else { return 1 }
    return max(0, value)
}()

/// Parse the independent direct expert-reduction control.
func gemma4FusedWeightedUnsortFlag(_ raw: String?) -> Bool {
    gemma4TruthyFlag(raw)
}

/// The retained weighted/R1 pair is measured only on scheduled CBv2 prefill.
/// Direct model forwards keep the established reduction path.
func gemma4AllowsWeightedExpertUnsort(schedulePrefill: Bool) -> Bool {
    schedulePrefill
}

/// The exact production expert topology. Near matches retain the established
/// unsort + weighted sum and the generic gather-QMM route.
func gemma4SupportsProductionExpertTopology(_ config: Gemma4TextConfiguration) -> Bool {
    config.enableMoeBlock
        && config.hiddenSize == 2816
        && config.numHiddenLayers == 30
        && config.numExperts == 128
        && config.topKExperts == 8
        && config.moeIntermediateSize == 704
        && config.useBidirectionalAttention == "vision"
}

/// The safe Gemma 4 expert-QMM selector (`classify_gemma4_expert_qmm`) rejects
/// anything that is not affine 4-bit at group size 64 with
/// `fallback_quantization`, before it ever looks at topology. The remaining
/// selector conditions (dtypes, contiguity, assignment count, AOT metallib,
/// NAX precedence) are dispatch-time facts MLX reports separately.
func gemma4HasExpertQuantizationOverrides(
    _ quantization: BaseConfiguration.PerLayerQuantization?
) -> Bool {
    quantization?.perLayerQuantization.keys.contains { path in
        path.split(separator: ".").contains("experts")
    } ?? false
}

func gemma4SupportsSafeExpertQMMQuantization(_ config: Gemma4TextConfiguration) -> Bool {
    config.quantizationBits == 4 && config.quantizationGroupSize == 64
        && config.quantizationMode == .affine
        && !config.hasExpertQuantizationOverrides
}

/// Direct weighted unsort and the safe expert-QMM (R1) kernel are one measured
/// unit. Weighted unsort on its own is materially slower than the retained
/// baseline, so it must never engage on a checkpoint where safe R1
/// categorically cannot — which is any checkpoint outside the exact production
/// topology *and* the selector's 4-bit / group-size-64 quantization contract.
/// Both features gate on this single predicate, so reported eligibility
/// matches real dispatch and no weighted-only state is reachable.
func gemma4SupportsCoupledExpertOptimizations(_ config: Gemma4TextConfiguration) -> Bool {
    gemma4SupportsProductionExpertTopology(config)
        && gemma4SupportsSafeExpertQMMQuantization(config)
}

internal let gemma4FusedWeightedUnsortRequested = gemma4FusedWeightedUnsortFlag(
    ProcessInfo.processInfo.environment["MLX_GEMMA4_FUSED_WEIGHTED_UNSORT"])

/// Pure policy seam for the weighted-unsort resolution, so the coupling with
/// safe R1 is unit-testable without building a production-sized model. The
/// request is the only thing separating this from `expertQMMGeometryEligible`.
func gemma4ShouldFuseWeightedUnsort(
    _ config: Gemma4TextConfiguration,
    requested: Bool = gemma4FusedWeightedUnsortRequested
) -> Bool {
    requested && gemma4SupportsCoupledExpertOptimizations(config)
}


/// Chunks shorter than this keep the unnarrowed final layer: the saving
/// scales with the discarded row count, and tiny chunks are dominated by
/// fixed overhead. Overridable so tests can exercise the narrow path on
/// small fixtures.
internal let gemma4PrefillTailMinChunk: Int = {
    guard let raw = ProcessInfo.processInfo.environment[
        "DARKBLOOM_GEMMA4_PREFILL_TAIL_MIN_CHUNK"],
        let value = Int(raw)
    else { return 128 }
    return max(2, value)
}()

/// Final-layer last-query prefill: project and cache the whole chunk's K/V
/// but compute Q and attention for the frontier row alone. Requires the tail
/// narrowing above (exactly one retained row) and a cache that can commit
/// full K/V for a single query. Default ON with
/// `DARKBLOOM_GEMMA4_PREFILL_LAST_QUERY=0` as the kill switch.
internal let gemma4PrefillLastQueryEnabled: Bool = {
    guard let raw = ProcessInfo.processInfo.environment[
        "DARKBLOOM_GEMMA4_PREFILL_LAST_QUERY"]
    else { return true }
    return gemma4TruthyFlag(raw)
}()

/// The final layer must own a full-attention, non-shared cache for
/// last-query prefill to be equivalent. Sliding windows give each query a
/// different visible span, and a KV-shared final layer writes nothing.
func gemma4SupportsLastQueryPrefill(_ config: Gemma4TextConfiguration) -> Bool {
    config.layerTypes.count == config.numHiddenLayers
        && config.layerTypes.last == "full_attention"
        && !config.layerUsesSharedKV(layerIdx: config.numHiddenLayers - 1)
}

/// Pure policy seam for the final layer's prompt specialization, so the
/// decision is unit-testable without building a model. Cache capability is
/// supplied by the caller: only the contiguous CBv2 cache exposes the
/// atomic full-K/V + last-query operation.
func gemma4UseLastQueryPrefill(
    _ config: Gemma4TextConfiguration,
    layerIdx: Int,
    batchSize: Int,
    sequenceLength: Int,
    outputTailRows: Int?,
    hasCapableCache: Bool,
    enabled: Bool = gemma4PrefillLastQueryEnabled
) -> Bool {
    enabled
        && hasCapableCache
        && outputTailRows == 1
        && layerIdx == config.numHiddenLayers - 1
        && batchSize > 0
        && sequenceLength > 1
        && gemma4SupportsLastQueryPrefill(config)
}

/// Approximate (tanh) GELU written with `x * x * x` instead of the Power
/// primitive (`x ** 3`) so it is safe under `compile(shapeless: true)` — the
/// Power primitive returns zero results on the Tahoe Metal JIT (MLX #3329).
/// Numerically identical to `MLXNN.geluApproximate` (vMLX `safeGeluApproximate`).
private let gemma4SafeGeluApproximate: @Sendable (MLXArray) -> MLXArray = {
    let body: @Sendable (MLXArray) -> MLXArray = { (x: MLXArray) -> MLXArray in
        0.5 * x * (1 + tanh(sqrt(2 / Float.pi) * (x + 0.044715 * x * x * x)))
    }
    return gemma4CompiledDecodeSupported ? cbv2ObservedCompiled(.gemmaGelu, compile(shapeless: true, body)) : body
}()

/// Final-logit softcap (`tanh(x / cap) * cap`) fused into one Metal dispatch
/// (vMLX `compiledLogitSoftcap`). The untyped (float32) cap keeps the softcap
/// math — and the logits handed to the sampler — full precision.
internal let gemma4CompiledLogitSoftcap: @Sendable (MLXArray, MLXArray) -> MLXArray = {
    let body: @Sendable (MLXArray, MLXArray) -> MLXArray = {
        (x: MLXArray, cap: MLXArray) -> MLXArray in
        tanh(x / cap) * cap
    }
    return gemma4CompiledDecodeSupported ? cbv2ObservedCompiled(.gemmaSoftcap, compile(shapeless: true, body)) : body
}()

// MARK: - Configuration

struct Gemma4WeightQuantizationMetadata: Codable, Sendable {
    var bits: Int?
    var groupSize: Int?
    var mode: QuantizationMode?

    enum CodingKeys: String, CodingKey {
        case bits
        case groupSize = "group_size"
        case mode
    }
}

private struct Gemma4WeightQuantizationConfiguration: Encodable {
    let fallback: Gemma4WeightQuantizationMetadata
    let overrides: [String: BaseConfiguration.QuantizationOption]

    private struct DynamicKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init(stringValue: String) { self.stringValue = stringValue }
        init(intValue: Int) { self.stringValue = "\(intValue)" }
    }

    func encode(to encoder: Encoder) throws {
        try fallback.encode(to: encoder)
        var container = encoder.container(keyedBy: DynamicKey.self)
        for (path, option) in overrides {
            switch option {
            case .skip:
                try container.encode(false, forKey: DynamicKey(stringValue: path))
            case .quantize(let quantization):
                try container.encode(quantization, forKey: DynamicKey(stringValue: path))
            }
        }
    }
}

/// Default profile used while decoding Gemma4 text configuration. Direct
/// language-model checkpoints and nested VLM checkpoints historically shipped
/// different omission semantics; selecting the profile at the decoder boundary
/// keeps one implementation without silently changing VLM topology.
public enum Gemma4TextConfigurationDefaults: Sendable, Equatable {
    case languageModel
    case visionLanguageModel
}

public struct Gemma4TextConfiguration: Codable, Sendable {
    public internal(set) var modelType: String = "gemma4_text"
    public internal(set) var hiddenSize: Int = 1536
    public internal(set) var numHiddenLayers: Int = 35
    public internal(set) var intermediateSize: Int = 6144
    public internal(set) var numAttentionHeads: Int = 8
    public internal(set) var headDim: Int = 256
    public internal(set) var globalHeadDim: Int = 512
    public internal(set) var globalPartialRotaryFactor: Float = 0.25
    public internal(set) var rmsNormEps: Float = 1e-6
    public internal(set) var vocabSize: Int = 262144
    public internal(set) var vocabSizePerLayerInput: Int = 262144
    public internal(set) var numKeyValueHeads: Int = 1
    public internal(set) var numGlobalKeyValueHeads: Int?
    public var numKvSharedLayers: Int = 20
    public internal(set) var hiddenSizePerLayerInput: Int = 256
    public internal(set) var slidingWindow: Int = 512
    public internal(set) var slidingWindowPattern: Int = 5
    public internal(set) var maxPositionEmbeddings: Int = 131072
    public internal(set) var attentionKeqV: Bool = false
    public internal(set) var finalLogitSoftcapping: Float = 30.0
    public internal(set) var useDoubleWideMlp: Bool = true
    public internal(set) var layerTypes: [String] = []
    public internal(set) var tieWordEmbeddings: Bool = true
    public internal(set) var quantizationBits: Int?
    public internal(set) var quantizationGroupSize: Int?
    public internal(set) var quantizationMode: QuantizationMode = .affine
    public internal(set) var perLayerQuantization: BaseConfiguration.PerLayerQuantization?
    /// Any explicit expert-path quantization entry makes the coupled
    /// weighted-unsort/R1 optimization fail closed. The runtime quantizer
    /// resolves these entries per module, so global bits/group size alone is
    /// not proof that every expert projection reaches safe R1.
    public var hasExpertQuantizationOverrides: Bool {
        gemma4HasExpertQuantizationOverrides(perLayerQuantization)
    }

    // MoE (only set on the 26B-A4B variant; 2B/4B/31B are dense)
    public internal(set) var enableMoeBlock: Bool = false
    public internal(set) var numExperts: Int?
    public internal(set) var topKExperts: Int?
    public internal(set) var moeIntermediateSize: Int?

    // RoPE parameters (nested dict with full_attention/sliding_attention sub-configs)
    public internal(set) var ropeParameters: [String: [String: StringOrNumber]]?

    // "vision" enables blockwise bidirectional attention within image/video
    // soft-token spans. "all" makes the full prefill bidirectional (bounded by
    // the configured window on sliding layers). nil/other remains causal.
    public internal(set) var useBidirectionalAttention: String?

    // Derived properties
    public internal(set) var slidingRopeTheta: Float = 10000.0
    public internal(set) var fullRopeTheta: Float = 1_000_000.0
    public internal(set) var fullPartialRotaryFactor: Float = 1.0

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case hiddenSize = "hidden_size"
        case numHiddenLayers = "num_hidden_layers"
        case intermediateSize = "intermediate_size"
        case numAttentionHeads = "num_attention_heads"
        case headDim = "head_dim"
        case globalHeadDim = "global_head_dim"
        case globalPartialRotaryFactor = "global_partial_rotary_factor"
        case rmsNormEps = "rms_norm_eps"
        case vocabSize = "vocab_size"
        case vocabSizePerLayerInput = "vocab_size_per_layer_input"
        case numKeyValueHeads = "num_key_value_heads"
        case numGlobalKeyValueHeads = "num_global_key_value_heads"
        case numKvSharedLayers = "num_kv_shared_layers"
        case hiddenSizePerLayerInput = "hidden_size_per_layer_input"
        case slidingWindow = "sliding_window"
        case slidingWindowPattern = "sliding_window_pattern"
        case maxPositionEmbeddings = "max_position_embeddings"
        case attentionKeqV = "attention_k_eq_v"
        case finalLogitSoftcapping = "final_logit_softcapping"
        case useDoubleWideMlp = "use_double_wide_mlp"
        case layerTypes = "layer_types"
        case tieWordEmbeddings = "tie_word_embeddings"
        case ropeParameters = "rope_parameters"
        case enableMoeBlock = "enable_moe_block"
        case numExperts = "num_experts"
        case topKExperts = "top_k_experts"
        case moeIntermediateSize = "moe_intermediate_size"
        case useBidirectionalAttention = "use_bidirectional_attention"
    }

    enum VLMCompatibilityCodingKeys: String, CodingKey {
        case attentionBias = "attention_bias"
        case ropeTraditional = "rope_traditional"
    }

    enum QuantizationCodingKeys: String, CodingKey {
        case quantization
        case quantizationConfig = "quantization_config"
    }

    /// The synthesized encoder silently dropped the effective quantization
    /// metadata (it has no `CodingKeys` case), so a
    /// decode→encode→decode round trip lost the nested quantization contract
    /// and a later strict load of a quantized checkpoint skipped quantization
    /// outright. Encode explicitly: every keyed property plus the nested
    /// `quantization` block in exactly the shape the decoder first looks for.
    /// The derived rope thetas/partial factor re-derive from `ropeParameters`
    /// on decode, so they are intentionally not keyed.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(modelType, forKey: .modelType)
        try c.encode(hiddenSize, forKey: .hiddenSize)
        try c.encode(numHiddenLayers, forKey: .numHiddenLayers)
        try c.encode(intermediateSize, forKey: .intermediateSize)
        try c.encode(numAttentionHeads, forKey: .numAttentionHeads)
        try c.encode(headDim, forKey: .headDim)
        try c.encode(globalHeadDim, forKey: .globalHeadDim)
        try c.encode(globalPartialRotaryFactor, forKey: .globalPartialRotaryFactor)
        try c.encode(rmsNormEps, forKey: .rmsNormEps)
        try c.encode(vocabSize, forKey: .vocabSize)
        try c.encode(vocabSizePerLayerInput, forKey: .vocabSizePerLayerInput)
        try c.encode(numKeyValueHeads, forKey: .numKeyValueHeads)
        try c.encodeIfPresent(numGlobalKeyValueHeads, forKey: .numGlobalKeyValueHeads)
        try c.encode(numKvSharedLayers, forKey: .numKvSharedLayers)
        try c.encode(hiddenSizePerLayerInput, forKey: .hiddenSizePerLayerInput)
        try c.encode(slidingWindow, forKey: .slidingWindow)
        try c.encode(slidingWindowPattern, forKey: .slidingWindowPattern)
        try c.encode(maxPositionEmbeddings, forKey: .maxPositionEmbeddings)
        try c.encode(attentionKeqV, forKey: .attentionKeqV)
        try c.encode(finalLogitSoftcapping, forKey: .finalLogitSoftcapping)
        try c.encode(useDoubleWideMlp, forKey: .useDoubleWideMlp)
        try c.encode(layerTypes, forKey: .layerTypes)
        try c.encode(tieWordEmbeddings, forKey: .tieWordEmbeddings)
        try c.encodeIfPresent(ropeParameters, forKey: .ropeParameters)
        try c.encode(enableMoeBlock, forKey: .enableMoeBlock)
        try c.encodeIfPresent(numExperts, forKey: .numExperts)
        try c.encodeIfPresent(topKExperts, forKey: .topKExperts)
        try c.encodeIfPresent(moeIntermediateSize, forKey: .moeIntermediateSize)
        try c.encodeIfPresent(useBidirectionalAttention, forKey: .useBidirectionalAttention)

        if quantizationBits != nil || quantizationGroupSize != nil {
            var qc = encoder.container(keyedBy: QuantizationCodingKeys.self)
            let metadata = Gemma4WeightQuantizationMetadata(
                bits: quantizationBits, groupSize: quantizationGroupSize,
                mode: quantizationMode)
            if let perLayerQuantization {
                try qc.encode(
                    Gemma4WeightQuantizationConfiguration(
                        fallback: metadata,
                        overrides: perLayerQuantization.perLayerQuantization),
                    forKey: .quantization)
            } else {
                try qc.encode(metadata, forKey: .quantization)
            }
        }
    }

    public init(from decoder: Decoder) throws {
        try self.init(from: decoder, defaults: .languageModel)
    }

    public init(
        from decoder: Decoder,
        defaults: Gemma4TextConfigurationDefaults
    ) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let quantizationContainer = try decoder.container(keyedBy: QuantizationCodingKeys.self)
        let baseConfiguration = try? BaseConfiguration(from: decoder)
        let perLayerQuantization = baseConfiguration?.perLayerQuantization
        let compatibilityContainer = try decoder.container(
            keyedBy: VLMCompatibilityCodingKeys.self)
        let isVLM = defaults == .visionLanguageModel
        if isVLM,
            try compatibilityContainer.decodeIfPresent(
                Bool.self, forKey: .attentionBias) == true
        {
            throw DecodingError.dataCorruptedError(
                forKey: .attentionBias,
                in: compatibilityContainer,
                debugDescription:
                    "Gemma4 VLM attention_bias=true is unsupported by the canonical text tower.")
        }
        if isVLM,
            try compatibilityContainer.decodeIfPresent(
                Bool.self, forKey: .ropeTraditional) == true
        {
            throw DecodingError.dataCorruptedError(
                forKey: .ropeTraditional,
                in: compatibilityContainer,
                debugDescription:
                    "Gemma4 VLM rope_traditional=true is unsupported by the canonical text tower.")
        }
        self.fullPartialRotaryFactor = isVLM ? 0.25 : 1.0

        self.modelType =
            try container.decodeIfPresent(String.self, forKey: .modelType) ?? "gemma4_text"
        self.hiddenSize =
            try container.decodeIfPresent(Int.self, forKey: .hiddenSize)
            ?? (isVLM ? 2816 : 1536)
        self.numHiddenLayers =
            try container.decodeIfPresent(Int.self, forKey: .numHiddenLayers)
            ?? (isVLM ? 30 : 35)
        self.intermediateSize =
            try container.decodeIfPresent(Int.self, forKey: .intermediateSize)
            ?? (isVLM ? 2112 : 6144)
        self.numAttentionHeads =
            try container.decodeIfPresent(Int.self, forKey: .numAttentionHeads)
            ?? (isVLM ? 16 : 8)
        self.headDim = try container.decodeIfPresent(Int.self, forKey: .headDim) ?? 256
        self.globalHeadDim = try container.decodeIfPresent(Int.self, forKey: .globalHeadDim) ?? 512
        self.globalPartialRotaryFactor =
            try container.decodeIfPresent(Float.self, forKey: .globalPartialRotaryFactor) ?? 0.25
        self.rmsNormEps = try container.decodeIfPresent(Float.self, forKey: .rmsNormEps) ?? 1e-6
        self.vocabSize = try container.decodeIfPresent(Int.self, forKey: .vocabSize) ?? 262144
        self.numKeyValueHeads =
            try container.decodeIfPresent(Int.self, forKey: .numKeyValueHeads)
            ?? (isVLM ? 8 : 1)
        self.numGlobalKeyValueHeads =
            try container.decodeIfPresent(Int.self, forKey: .numGlobalKeyValueHeads)

        let decodedHiddenSizePerLayerInput =
            try container.decodeIfPresent(Int.self, forKey: .hiddenSizePerLayerInput)
            ?? (isVLM ? 0 : 256)
        var decodedVocabSizePerLayerInput =
            try container.decodeIfPresent(Int.self, forKey: .vocabSizePerLayerInput)
            ?? (isVLM ? 0 : 262144)
        if isVLM {
            // Preserve the former nested VLM DTO's PLE contract: zero hidden
            // width disables both tensors, while positive hidden width requires
            // an explicitly positive vocabulary width.
            if decodedHiddenSizePerLayerInput == 0 {
                decodedVocabSizePerLayerInput = 0
            } else if decodedVocabSizePerLayerInput == 0 {
                throw DecodingError.dataCorruptedError(
                    forKey: .hiddenSizePerLayerInput,
                    in: container,
                    debugDescription:
                        "Gemma4 VLM PLE config requires positive vocab_size_per_layer_input when hidden_size_per_layer_input is positive.")
            }
        }
        self.hiddenSizePerLayerInput = decodedHiddenSizePerLayerInput
        self.vocabSizePerLayerInput = decodedVocabSizePerLayerInput
        self.numKvSharedLayers =
            try container.decodeIfPresent(Int.self, forKey: .numKvSharedLayers)
            ?? (isVLM ? 0 : 20)
        self.slidingWindow =
            try container.decodeIfPresent(Int.self, forKey: .slidingWindow)
            ?? (isVLM ? 1024 : 512)
        self.slidingWindowPattern =
            try container.decodeIfPresent(Int.self, forKey: .slidingWindowPattern) ?? 5
        self.maxPositionEmbeddings =
            try container.decodeIfPresent(Int.self, forKey: .maxPositionEmbeddings) ?? 131072
        self.attentionKeqV =
            try container.decodeIfPresent(Bool.self, forKey: .attentionKeqV) ?? false
        self.finalLogitSoftcapping =
            try container.decodeIfPresent(Float.self, forKey: .finalLogitSoftcapping)
            ?? (isVLM ? 0 : 30.0)
        self.useDoubleWideMlp =
            try container.decodeIfPresent(Bool.self, forKey: .useDoubleWideMlp)
            ?? !isVLM
        if let decoded = try container.decodeIfPresent([String].self, forKey: .layerTypes) {
            if decoded.isEmpty {
                // The deleted VLM tower interpreted an explicit empty list as
                // all sliding-attention layers (non-VLM checkpoints inherit
                // the same robust fallback rather than trapping later).
                self.layerTypes = Array(
                    repeating: "sliding_attention", count: numHiddenLayers)
            } else if decoded.count < numHiddenLayers {
                // The deleted towers fell back to sliding attention for
                // out-of-range layer indices; normalize short explicit lists
                // by padding instead of trapping at model construction.
                self.layerTypes =
                    decoded
                    + Array(
                        repeating: "sliding_attention",
                        count: numHiddenLayers - decoded.count)
            } else {
                self.layerTypes = Array(decoded.prefix(numHiddenLayers))
            }
        } else if isVLM {
            // The same VLM fallback applies when the key is absent.
            self.layerTypes = Array(
                repeating: "sliding_attention", count: numHiddenLayers)
        } else {
            var pattern = [String]()
            for i in 0 ..< slidingWindowPattern {
                pattern.append(
                    i == slidingWindowPattern - 1 ? "full_attention" : "sliding_attention")
            }
            var types = [String]()
            while types.count < numHiddenLayers {
                types.append(contentsOf: pattern)
            }
            self.layerTypes = Array(types.prefix(numHiddenLayers))
        }
        self.tieWordEmbeddings =
            try container.decodeIfPresent(Bool.self, forKey: .tieWordEmbeddings) ?? true
        let quantization =
            try quantizationContainer.decodeIfPresent(
                Gemma4WeightQuantizationMetadata.self, forKey: .quantization)
            ?? quantizationContainer.decodeIfPresent(
                Gemma4WeightQuantizationMetadata.self, forKey: .quantizationConfig)
        self.quantizationBits = quantization?.bits
        self.quantizationGroupSize = quantization?.groupSize
        self.quantizationMode =
            perLayerQuantization?.quantization?.mode ?? quantization?.mode ?? .affine
        self.perLayerQuantization = perLayerQuantization
        self.ropeParameters =
            try container.decodeIfPresent(
                [String: [String: StringOrNumber]].self, forKey: .ropeParameters)

        self.enableMoeBlock =
            try container.decodeIfPresent(Bool.self, forKey: .enableMoeBlock) ?? false
        self.numExperts = try container.decodeIfPresent(Int.self, forKey: .numExperts)
        self.topKExperts = try container.decodeIfPresent(Int.self, forKey: .topKExperts)
        self.moeIntermediateSize =
            try container.decodeIfPresent(Int.self, forKey: .moeIntermediateSize)
        self.useBidirectionalAttention =
            try container.decodeIfPresent(String.self, forKey: .useBidirectionalAttention)

        if let ropeParams = ropeParameters {
            if let sliding = ropeParams["sliding_attention"] {
                self.slidingRopeTheta = sliding["rope_theta"]?.asFloat() ?? 10000.0
            }
            if let full = ropeParams["full_attention"] {
                self.fullRopeTheta = full["rope_theta"]?.asFloat() ?? 1_000_000.0
                self.fullPartialRotaryFactor =
                    full["partial_rotary_factor"]?.asFloat()
                    ?? (isVLM ? 0.25 : 1.0)
            }
        }
    }
}

extension Gemma4TextConfiguration {
    /// Overlay checkpoint-level quantization metadata on a decoded text
    /// configuration. VLM checkpoints commonly keep this metadata beside
    /// `text_config`; an absent overlay preserves any nested metadata.
    public mutating func mergeQuantization(
        _ quantization: BaseConfiguration.Quantization?
    ) {
        guard let quantization else { return }
        quantizationBits = quantization.bits
        quantizationGroupSize = quantization.groupSize
        quantizationMode = quantization.mode
        if var effective = perLayerQuantization {
            effective.quantization = quantization
            perLayerQuantization = effective
        }
    }

    /// Overlay the effective root mixed-precision map used by the model
    /// loader. Expert-path entries make the coupled optimization fail closed,
    /// even when the root default remains nominally 4-bit/group-64.
    public mutating func mergeQuantization(
        _ quantization: BaseConfiguration.PerLayerQuantization?
    ) {
        guard let quantization else { return }
        if let fallback = quantization.quantization {
            quantizationBits = fallback.bits
            quantizationGroupSize = fallback.groupSize
            quantizationMode = fallback.mode
        }
        perLayerQuantization = quantization
    }
}

extension Gemma4TextConfiguration {

    /// Predicate for whether a layer uses shared K/V (consuming it from an
    /// earlier layer rather than projecting its own).
    ///
    /// A layer is shared when either:
    /// - `forceSharedKV` is true (drafter / assistant models where every layer
    ///   borrows K/V from the target), or
    /// - the config declares `numKvSharedLayers > 0` AND this layer's index
    ///   falls within the trailing shared block.
    public func layerUsesSharedKV(layerIdx: Int, forceSharedKV: Bool = false) -> Bool {
        if forceSharedKV { return true }
        guard numKvSharedLayers > 0 else { return false }
        let firstShared = numHiddenLayers - numKvSharedLayers
        return layerIdx >= firstShared
    }
}

// MARK: - Helper Modules

private class RMSNormNoScale: Module {
    let eps: Float

    init(eps: Float = 1e-6) {
        self.eps = eps
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        MLXFast.rmsNorm(x, weight: MLXArray.mlxNone, eps: eps)
    }
}

private class ScaledLinear: Module {
    let weight: MLXArray
    let scalar: Float

    init(inFeatures: Int, outFeatures: Int, scalar: Float) {
        self.weight = MLXArray.zeros([outFeatures, inFeatures])
        self.scalar = scalar
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        matmul(x, weight.T) * scalar
    }
}

@inline(__always)
internal func gemma4CapturePositionOffset(from cache: KVCache?) -> Gemma4.PositionOffset {
    if let compilableRot = cache as? CompilableRotatingKVCache {
        // Snapshot: `+ 0` creates a graph-safe copy so cache.update()
        // advancing offsetArray doesn't shift the query RoPE position.
        .graphArray(compilableRot.offsetArray + 0)
    } else if let compilable = cache as? CompilableKVCache {
        // Snapshot: `+ 0` creates a graph-safe copy so cache.update()
        // advancing offsetArray doesn't shift the query RoPE position.
        .graphArray(compilable.offsetArray + 0)
    } else if let batchCache = cache as? BatchPositionedKVCache {
        // Snapshot the per-sequence offsets before cache.update(...) advances them.
        .batch(batchCache.batchOffset + 0)
    } else {
        .scalar(cache?.offset ?? 0)
    }
}

@inline(__always)
internal func gemma4ApplyRotaryPosition<R: RoPELayer>(
    _ rope: R,
    to x: MLXArray,
    offset: Gemma4.PositionOffset
) -> MLXArray {
    switch offset {
    case .scalar(let value):
        rope(x, offset: value)
    case .batch(let values):
        rope(x, offset: values)
    case .graphArray(let offsetArray):
        rope(x, offset: offsetArray)
    }
}

private func gemma4AttentionFallback(
    queries: MLXArray,
    keys: MLXArray,
    values: MLXArray,
    scale: Float,
    mask: MLXFast.ScaledDotProductAttentionMaskMode
) -> MLXArray {
    let (B, nQHeads, L, D) = (
        queries.dim(0), queries.dim(1), queries.dim(2), queries.dim(3)
    )
    let nKVHeads = keys.dim(1)
    let repeats = nQHeads / nKVHeads

    var q = queries * scale
    var k = keys
    var v = values
    if repeats > 1 {
        q = q.reshaped([B, nKVHeads, repeats, L, D])
        k = expandedDimensions(k, axis: 2)
        v = expandedDimensions(v, axis: 2)
    }

    var scores = matmul(q, k.swappedAxes(-1, -2))

    func applyMask(_ maskArray: MLXArray) {
        var mask = maskArray
        if scores.ndim == 5 && mask.ndim == 4 && mask.dim(0) == scores.dim(0) {
            mask = expandedDimensions(mask, axis: 2)
        }
        if mask.dtype == .bool {
            scores = MLX.where(
                mask, scores, MLXArray(-Float.infinity, dtype: scores.dtype))
        } else {
            scores = scores + mask
        }
    }

    switch mask {
    case .none:
        break
    case .causal:
        let qL = scores.dim(-2)
        let kL = scores.dim(-1)
        let qIndices = MLXArray(0 ..< qL) + MLXArray(kL - qL)
        let kIndices = MLXArray(0 ..< kL)
        let causalMask = greaterEqual(
            expandedDimensions(qIndices, axis: -1),
            expandedDimensions(kIndices, axis: -2))
        applyMask(causalMask)
    case .array(let maskArray):
        applyMask(maskArray)
    case .arrays(let maskArrays):
        if let maskArray = maskArrays.first {
            applyMask(maskArray)
        }
    }

    var probs = softmax(scores.asType(.float32), axis: -1, precise: true)
    // A fully-masked query row (every key masked -> all -inf) softmaxes to NaN.
    // For left-padded batches these are the padding query positions, whose
    // outputs are discarded — but `0 * NaN = NaN` in the value matmul below
    // would propagate NaN into the hidden state, and a later layer's real
    // queries (which mask padding keys to weight 0) then hit `0 * NaN` again
    // and corrupt EVERY row of the batch. Map NaN -> 0 so a fully-masked query
    // contributes nothing. This matches `MLXFast.scaledDotProductAttention`,
    // which this manual fallback replaces for the batched (ragged) path.
    probs = MLX.where(probs .!= probs, MLXArray(Float(0)), probs)
    scores = probs.asType(scores.dtype)
    var output = matmul(scores, v)
    if repeats > 1 {
        output = output.reshaped([B, nQHeads, L, values.dim(3)])
    }
    return output
}

// MARK: - Attention

private class Gemma4Attention: Module {
    let config: Gemma4TextConfiguration
    let layerIdx: Int
    let layerType: String
    let isSliding: Bool
    let effectiveHeadDim: Int
    let nHeads: Int
    let nKvHeads: Int
    let useKeqV: Bool
    let usesSharedKV: Bool
    let scale: Float

    @ModuleInfo(key: "q_proj") var qProj: Linear
    @ModuleInfo(key: "k_proj") var kProj: Linear?
    @ModuleInfo(key: "v_proj") var vProj: Linear?
    @ModuleInfo(key: "o_proj") var oProj: Linear

    @ModuleInfo(key: "q_norm") var qNorm: RMSNorm
    @ModuleInfo(key: "k_norm") var kNorm: RMSNorm?
    @ModuleInfo(key: "v_norm") var vNorm: RMSNormNoScale?

    @ModuleInfo var rope: RoPELayer

    init(_ config: Gemma4TextConfiguration, layerIdx: Int, forceSharedKV: Bool = false) {
        self.config = config
        self.layerIdx = layerIdx
        self.layerType = config.layerTypes[layerIdx]
        self.isSliding = layerType == "sliding_attention"
        self.usesSharedKV = config.layerUsesSharedKV(
            layerIdx: layerIdx, forceSharedKV: forceSharedKV)

        // Full attention uses globalHeadDim, sliding uses headDim
        self.effectiveHeadDim =
            isSliding ? config.headDim : config.globalHeadDim

        let dim = config.hiddenSize
        self.nHeads = config.numAttentionHeads

        // K-eq-V for full attention layers
        self.useKeqV = config.attentionKeqV && !isSliding
        // Full layers honor `num_global_key_value_heads` whenever it is
        // present, independent of `attention_k_eq_v`; k_eq_v only elides the
        // v_proj. This restores the deleted inline VLM tower's rule — a full
        // layer with global heads different from the sliding count and
        // k_eq_v=false still allocates its K/V projections for the global
        // count, matching such checkpoints' weights.
        if !isSliding, let globalKvHeads = config.numGlobalKeyValueHeads {
            self.nKvHeads = globalKvHeads
        } else {
            self.nKvHeads = config.numKeyValueHeads
        }

        self.scale = 1.0

        self._qProj.wrappedValue = Linear(dim, nHeads * effectiveHeadDim, bias: false)
        if !usesSharedKV {
            self._kProj.wrappedValue = Linear(dim, nKvHeads * effectiveHeadDim, bias: false)
            if !useKeqV {
                self._vProj.wrappedValue = Linear(dim, nKvHeads * effectiveHeadDim, bias: false)
            }
            self._kNorm.wrappedValue = RMSNorm(dimensions: effectiveHeadDim, eps: config.rmsNormEps)
            self._vNorm.wrappedValue = RMSNormNoScale(eps: config.rmsNormEps)
        }
        self._oProj.wrappedValue = Linear(nHeads * effectiveHeadDim, dim, bias: false)

        self._qNorm.wrappedValue = RMSNorm(dimensions: effectiveHeadDim, eps: config.rmsNormEps)

        // RoPE: sliding uses default, full uses proportional with partial rotation
        if isSliding {
            self.rope = initializeRope(
                dims: effectiveHeadDim, base: config.slidingRopeTheta, traditional: false,
                scalingConfig: nil, maxPositionEmbeddings: nil)
        } else {
            self.rope = initializeRope(
                dims: effectiveHeadDim, base: config.fullRopeTheta, traditional: false,
                scalingConfig: [
                    "type": .string("proportional"),
                    "partial_rotary_factor": .float(config.fullPartialRotaryFactor),
                ],
                maxPositionEmbeddings: nil)
        }

        super.init()
    }

    func callAsFunction(
        _ x: MLXArray,
        mask: MLXFast.ScaledDotProductAttentionMaskMode? = nil,
        cache: KVCache? = nil,
        sharedKV: (MLXArray, MLXArray)? = nil,
        positionOffset: Gemma4.PositionOffset? = nil,
        v2SharedSource: (any CBv2AttendingLayerCache)? = nil,
        outputStart: Int = 0,
        useLastQueryPrefill: Bool = false
    ) -> (MLXArray, (MLXArray, MLXArray), Gemma4.PositionOffset) {
        // ContinuousBatchingV2: the layer cache owns both the KV update and
        // the attention computation (no masks, no padding — see
        // CBv2Contracts.swift). Entirely separate branch; the legacy paths
        // below are untouched.
        if let layerCacheV2 = cache as? (any CBv2AttendingLayerCache) {
            return forwardV2(
                x, layerCache: layerCacheV2, source: v2SharedSource,
                sharedKV: sharedKV, positionOffset: positionOffset,
                outputStart: outputStart, useLastQueryPrefill: useLastQueryPrefill)
        }
        precondition(
            outputStart == 0 && !useLastQueryPrefill,
            "Gemma4: prompt output narrowing is a CBv2-only path")

        let (B, L, _) = (x.dim(0), x.dim(1), x.dim(2))

        var queries = qProj(x).reshaped(B, L, nHeads, effectiveHeadDim)
        queries = qNorm(queries)

        let keys: MLXArray
        let values: MLXArray
        let activePositionOffset = positionOffset ?? gemma4CapturePositionOffset(from: cache)

        if let (sharedK, sharedV) = sharedKV {
            // KV-shared layers use pre-computed KV from an earlier layer
            keys = sharedK
            values = sharedV
        } else {
            guard let kProj, let kNorm, let vNorm else {
                preconditionFailure("Gemma4 shared-KV layers require sharedKV input")
            }

            let kRaw = kProj(x).reshaped(B, L, nKvHeads, effectiveHeadDim)
            var k = kNorm(kRaw)
            k = k.transposed(0, 2, 1, 3)
            k = gemma4ApplyRotaryPosition(rope, to: k, offset: activePositionOffset)

            // K-eq-V (`attention_k_eq_v: true` on Gemma 4 26B/31B):
            // values reuses the raw key projection (pre-norm), then goes
            // through its own `vNorm` and transpose to land in the same
            // `[B, n_kv_heads, L, D]` layout as keys.
            var v: MLXArray
            if let vProj {
                v = vProj(x).reshaped(B, L, nKvHeads, effectiveHeadDim)
            } else {
                v = kRaw
            }
            v = vNorm(v)
            v = v.transposed(0, 2, 1, 3)

            if let cache {
                let (updatedK, updatedV) = cache.update(keys: k, values: v)
                keys = updatedK
                values = updatedV
            } else {
                keys = k
                values = v
            }
        }

        queries = queries.transposed(0, 2, 1, 3)
        queries = gemma4ApplyRotaryPosition(rope, to: queries, offset: activePositionOffset)

        // Adjust mask if cache size differs from mask size
        var adjustedMask = mask
        if case .array(let maskArray) = mask {
            let keysSeqLen = keys.dim(2)
            if maskArray.dim(-1) != keysSeqLen {
                adjustedMask = .array(maskArray[.ellipsis, 0 ..< keysSeqLen])
            }
        }

        let hasCachedPrefix: Bool
        switch activePositionOffset {
        case .scalar(let offset):
            hasCachedPrefix = offset > 0
        case .batch:
            hasCachedPrefix = true
        case .graphArray:
            // CompilableKVCache: can't read Int offset without readback.
            // During compiled decode L==1, so L>1 && hasCachedPrefix is
            // false anyway. Setting true is safe for the prefill path.
            hasCachedPrefix = true
        }

        // vmlx #52 text-path: Gemma 4 attention scores can exceed the fp16
        // range (±65504) on long contexts, and the fused/composed SDPA shapes
        // would materialize non-finite intermediates. Promote Q/K/V to
        // float32 for the attention math when the activation dtype is fp16,
        // then cast back so `oProj` sees its own dtype. Mirrors the deleted
        // inline VLM twin; bf16 activations (production) skip the cast.
        // The CBv2 path applies the same promotion to queries below; its cache
        // keeps K/V in their storage dtype and widens the attention views.
        let attentionInputDType = queries.dtype
        var attentionQueries = queries
        var attentionKeys = keys
        var attentionValues = values
        if attentionInputDType == .float16 {
            attentionQueries = attentionQueries.asType(.float32)
            attentionKeys = attentionKeys.asType(.float32)
            attentionValues = attentionValues.asType(.float32)
        }

        let attentionRaw: MLXArray
        if L > 1 && hasCachedPrefix {
            attentionRaw = gemma4AttentionFallback(
                queries: attentionQueries,
                keys: attentionKeys,
                values: attentionValues,
                scale: scale,
                mask: adjustedMask ?? .none)
        } else {
            attentionRaw = MLXFast.scaledDotProductAttention(
                queries: attentionQueries,
                keys: attentionKeys,
                values: attentionValues,
                scale: scale,
                mask: adjustedMask ?? .none
            )
        }
        let attention =
            attentionInputDType == .float16
            ? attentionRaw.asType(.float16) : attentionRaw

        let output = attention
        .transposed(0, 2, 1, 3)
        .reshaped(B, L, -1)

        return (oProj(output), (keys, values), activePositionOffset)
    }

    /// ContinuousBatchingV2 attention path. The `CBv2AttendingLayerCache`
    /// owns the KV update AND the attention computation, so this method only
    /// projects/normalizes/ropes Q (and K/V for non-shared layers) and
    /// dispatches. The model never builds masks and never pads — decode is
    /// rectangular `[B, 1]`, prefill is per-request `[1, chunk]`.
    ///
    /// Invariant 1 (report 10 §4): RoPE offsets are per-row absolutes,
    /// snapshotted BEFORE `updateAndAttend` advances the rows, and KV-shared
    /// layers reuse the SOURCE layer's captured snapshot byte-identically.
    private func forwardV2(
        _ x: MLXArray,
        layerCache: any CBv2AttendingLayerCache,
        source: (any CBv2AttendingLayerCache)?,
        sharedKV: (MLXArray, MLXArray)?,
        positionOffset: Gemma4.PositionOffset?,
        outputStart: Int = 0,
        useLastQueryPrefill: Bool = false
    ) -> (MLXArray, (MLXArray, MLXArray), Gemma4.PositionOffset) {
        let (B, L) = (x.dim(0), x.dim(1))
        precondition(
            outputStart >= 0 && outputStart < L,
            "Gemma4: output narrowing start \(outputStart) outside chunk length \(L)")

        // Last-query prefill projects Q for the frontier row only. Every
        // other path keeps the full query rectangle and narrows (if at all)
        // AFTER attention.
        let lastQueryCache: (any CBv2LastQueryPrefillLayerCache)? =
            useLastQueryPrefill
            ? layerCache as? (any CBv2LastQueryPrefillLayerCache) : nil
        if useLastQueryPrefill {
            precondition(
                lastQueryCache != nil,
                "Gemma4 last-query prefill requires a capable layer cache")
            precondition(
                B > 0 && L > 1 && outputStart == L - 1 && !isSliding && !usesSharedKV,
                "Gemma4 last-query prefill requires a final-row, non-shared, full-attention layer")
        }

        let queryInput = lastQueryCache == nil ? x : x[0..., outputStart..., 0...]
        let queryLength = queryInput.dim(1)

        var queries = qProj(queryInput).reshaped(B, queryLength, nHeads, effectiveHeadDim)
        queries = qNorm(queries)
        queries = queries.transposed(0, 2, 1, 3)

        if usesSharedKV {
            // KV-shared layer: projects queries only and borrows (K, V) from
            // the source layer's cache at attention time. The RoPE offsets
            // MUST be the source layer's pre-update snapshot (threaded by the
            // trunk) — reading `source.positionOffsets` here would observe
            // positions already advanced by the source's update this step.
            guard let source, let positionOffset, let sharedKV else {
                preconditionFailure(
                    """
                    Gemma4 CBv2 shared-KV layer \(layerIdx) requires the source \
                    layer cache, its captured position offsets, and its per-step \
                    K/V (threaded by Gemma4TextModelInner)
                    """)
            }
            queries = gemma4ApplyRotaryPosition(rope, to: queries, offset: positionOffset)
            let outputDType = queries.dtype
            let attentionQueries =
                outputDType == .float16 ? queries.asType(.float32) : queries
            let attention = layerCache.attendBorrowing(
                source: source, queries: attentionQueries, scale: scale, sinks: nil)
            var output = attention.transposed(0, 2, 1, 3).reshaped(B, L, -1)
            if outputStart > 0 {
                output = output[0..., outputStart..., 0...]
            }
            if output.dtype != outputDType {
                output = output.asType(outputDType)
            }
            return (oProj(output), sharedKV, positionOffset)
        }

        guard let kProj, let kNorm, let vNorm else {
            preconditionFailure("Gemma4 non-shared layers require K/V projection modules")
        }

        // Snapshot the per-row absolute offsets BEFORE updateAndAttend
        // advances the rows (`+ 0` = graph-safe copy, same convention as
        // gemma4CapturePositionOffset). KV-shared consumers of this layer
        // reuse this exact snapshot via the returned PositionOffset.
        let capturedOffsets = layerCache.positionOffsets + 0
        let captured = Gemma4.PositionOffset.batch(capturedOffsets)

        // The frontier query sits `outputStart` positions past the chunk's
        // first token, so last-query prefill must shift its RoPE position.
        // K/V keep the unshifted capture: they cover the whole chunk.
        let queryPositionOffset: Gemma4.PositionOffset =
            lastQueryCache == nil
            ? captured
            : .batch(capturedOffsets + Int32(outputStart))
        queries = gemma4ApplyRotaryPosition(rope, to: queries, offset: queryPositionOffset)

        let kRaw = kProj(x).reshaped(B, L, nKvHeads, effectiveHeadDim)
        var k = kNorm(kRaw)
        k = k.transposed(0, 2, 1, 3)
        k = gemma4ApplyRotaryPosition(rope, to: k, offset: captured)

        // K-eq-V (`attention_k_eq_v: true` on Gemma 4 26B/31B): values reuse
        // the raw key projection (pre-norm) through their own vNorm — same as
        // the legacy path.
        var v: MLXArray
        if let vProj {
            v = vProj(x).reshaped(B, L, nKvHeads, effectiveHeadDim)
        } else {
            v = kRaw
        }
        v = vNorm(v)
        v = v.transposed(0, 2, 1, 3)

        let outputDType = queries.dtype
        let attentionQueries =
            outputDType == .float16 ? queries.asType(.float32) : queries
        let attention: MLXArray
        if let lastQueryCache {
            attention = lastQueryCache.updateAndAttendLastQuery(
                queries: attentionQueries, keys: k, values: v, scale: scale, sinks: nil)
        } else {
            attention = layerCache.updateAndAttend(
                queries: attentionQueries, keys: k, values: v, scale: scale, sinks: nil)
        }

        var output = attention.transposed(0, 2, 1, 3).reshaped(B, queryLength, -1)
        if lastQueryCache == nil && outputStart > 0 {
            output = output[0..., outputStart..., 0...]
        }
        if output.dtype != outputDType {
            output = output.asType(outputDType)
        }
        return (oProj(output), (k, v), captured)
    }
}

// MARK: - MoE (26B-A4B)

/// Expert router. Norms `x` with a learnable scale, projects to expert
/// scores, and returns top-K (indices, weights) where weights are
/// softmax-normalized and scaled by a per-expert scalar.
private class Gemma4Router: Module {
    @ModuleInfo(key: "proj") var proj: Linear
    @ModuleInfo(key: "scale") var scale: MLXArray
    @ModuleInfo(key: "per_expert_scale") var perExpertScale: MLXArray

    let topK: Int
    let eps: Float
    let rootSize: Float

    init(_ config: Gemma4TextConfiguration) {
        precondition(
            config.numExperts != nil && config.topKExperts != nil,
            "Gemma4Router requires num_experts and top_k_experts in the config"
        )
        let numExperts = config.numExperts ?? 0
        self.topK = config.topKExperts ?? 0
        self.eps = config.rmsNormEps
        self.rootSize = pow(Float(config.hiddenSize), -0.5)

        self._proj.wrappedValue = Linear(config.hiddenSize, numExperts, bias: false)
        self._scale.wrappedValue = MLXArray.ones([config.hiddenSize])
        self._perExpertScale.wrappedValue = MLXArray.ones([numExperts])
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> (topKIndices: MLXArray, topKWeights: MLXArray) {
        let normed = MLXFast.rmsNorm(x, weight: scale * rootSize, eps: eps)
        let expertScores = proj(normed)

        let kth = expertScores.dim(-1) - topK
        var topKIndices = MLX.argPartition(expertScores, kth: kth, axis: -1)
        topKIndices = topKIndices[.ellipsis, kth...]

        var topKWeights = MLX.takeAlong(expertScores, topKIndices, axis: -1)
        topKWeights = MLX.softmax(topKWeights, axis: -1, precise: true)
        topKWeights = topKWeights * perExpertScale[topKIndices]

        return (topKIndices, topKWeights)
    }
}

/// Sparse MoE feed-forward block. Wraps `SwitchGLU` with GeGLU activation.
private class Gemma4Experts: Module {
    @ModuleInfo(key: "switch_glu") var switchGLU: SwitchGLU
    let fuseWeightedUnsort: Bool

    init(
        _ config: Gemma4TextConfiguration,
        fuseWeightedUnsort: Bool = false
    ) {
        let numExperts = config.numExperts ?? 1
        let moeIntermediate = config.moeIntermediateSize ?? config.intermediateSize
        self.fuseWeightedUnsort = fuseWeightedUnsort

        self._switchGLU.wrappedValue = SwitchGLU(
            inputDims: config.hiddenSize,
            hiddenDims: moeIntermediate,
            numExperts: numExperts,
            activation: { gemma4SafeGeluApproximate($0) },
            bias: false,
            weightedReductionProfile: .gemma4ProductionGeGLU
        )
        super.init()
    }

    func callAsFunction(
        _ x: MLXArray,
        topKIndices: MLXArray,
        topKWeights: MLXArray,
        isExpertPrefill: Bool
    ) -> MLXArray {
        // Flatten [B, S, H] and always enter SwitchGLU's combined API. It
        // selects direct sorted reduction only for the exact production
        // contract; every other case performs the established unsort + sum.
        let (B, S, H) = (x.dim(0), x.dim(1), x.dim(2))
        let K = topKIndices.dim(-1)
        let y = switchGLU.callAndWeightedReduce(
            x.reshaped(B * S, H),
            topKIndices.reshaped(B * S, K),
            weights: topKWeights.reshaped(B * S, K),
            fuseSortedReduction: fuseWeightedUnsort,
            // Ordinary/direct VLM and CBv2 prompt entry points may engage.
            // Rectangular MTP verification explicitly passes false.
            isProductionPrefill: isExpertPrefill)
        return y.reshaped(B, S, H)
    }
}

// MARK: - MLP

private class Gemma4MLP: Module {
    @ModuleInfo(key: "gate_proj") var gateProj: Linear
    @ModuleInfo(key: "up_proj") var upProj: Linear
    @ModuleInfo(key: "down_proj") var downProj: Linear

    init(_ config: Gemma4TextConfiguration, layerIdx: Int) {
        let isKvSharedLayer = config.layerUsesSharedKV(layerIdx: layerIdx)
        let useDoubleWide = config.useDoubleWideMlp && isKvSharedLayer
        let intermediateSize = config.intermediateSize * (useDoubleWide ? 2 : 1)

        self._gateProj.wrappedValue = Linear(config.hiddenSize, intermediateSize, bias: false)
        self._downProj.wrappedValue = Linear(intermediateSize, config.hiddenSize, bias: false)
        self._upProj.wrappedValue = Linear(config.hiddenSize, intermediateSize, bias: false)

        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        downProj(gemma4SafeGeluApproximate(gateProj(x)) * upProj(x))
    }
}

// MARK: - Decoder Layer

/// Gemma 4 decoder layer. Combines `Gemma4Attention` with an MLP (or MoE)
/// block, the per-layer-input (PLE) path, and residual / layer-scalar
/// plumbing. Consumed by `Gemma4TextModelInner` and by the Gemma 4 MTP
/// drafter's trunk in `Gemma4MTP`; not intended as a user-facing
/// composable layer.
public class Gemma4DecoderLayer: Module {
    let config: Gemma4TextConfiguration
    let layerIdx: Int
    let layerType: String
    let hiddenSizePerLayerInput: Int

    @ModuleInfo(key: "self_attn") fileprivate var selfAttn: Gemma4Attention
    @ModuleInfo fileprivate var mlp: Gemma4MLP
    @ModuleInfo(key: "input_layernorm") var inputLayernorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayernorm: RMSNorm
    @ModuleInfo(key: "pre_feedforward_layernorm") var preFeedforwardLayernorm: RMSNorm
    @ModuleInfo(key: "post_feedforward_layernorm") var postFeedforwardLayernorm: RMSNorm

    // MoE-only modules (26B-A4B); nil on dense variants.
    @ModuleInfo(key: "router") fileprivate var router: Gemma4Router?
    @ModuleInfo(key: "experts") fileprivate var experts: Gemma4Experts?
    @ModuleInfo(key: "post_feedforward_layernorm_1") var postFeedforwardLayernorm1: RMSNorm?
    @ModuleInfo(key: "pre_feedforward_layernorm_2") var preFeedforwardLayernorm2: RMSNorm?
    @ModuleInfo(key: "post_feedforward_layernorm_2") var postFeedforwardLayernorm2: RMSNorm?

    // Per-layer input (PLE) gating
    @ModuleInfo(key: "per_layer_input_gate") var perLayerInputGate: Linear?
    @ModuleInfo(key: "per_layer_projection") var perLayerProjection: Linear?
    @ModuleInfo(key: "post_per_layer_input_norm") var postPerLayerInputNorm: RMSNorm?

    // Per-layer scalar
    @ModuleInfo(key: "layer_scalar") var layerScalar: MLXArray

    let isMoE: Bool

    public init(
        _ config: Gemma4TextConfiguration, layerIdx: Int, forceSharedKV: Bool = false,
        fuseWeightedUnsort: Bool = false
    ) {
        self.config = config
        self.layerIdx = layerIdx
        self.layerType = config.layerTypes[layerIdx]
        self.hiddenSizePerLayerInput = config.hiddenSizePerLayerInput
        self.isMoE = config.enableMoeBlock

        self._selfAttn.wrappedValue = Gemma4Attention(
            config, layerIdx: layerIdx, forceSharedKV: forceSharedKV)
        self._mlp.wrappedValue = Gemma4MLP(config, layerIdx: layerIdx)

        self._inputLayernorm.wrappedValue = RMSNorm(
            dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self._postAttentionLayernorm.wrappedValue = RMSNorm(
            dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self._preFeedforwardLayernorm.wrappedValue = RMSNorm(
            dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self._postFeedforwardLayernorm.wrappedValue = RMSNorm(
            dimensions: config.hiddenSize, eps: config.rmsNormEps)

        if config.enableMoeBlock {
            self._router.wrappedValue = Gemma4Router(config)
            self._experts.wrappedValue = Gemma4Experts(
                config,
                fuseWeightedUnsort: fuseWeightedUnsort)
            self._postFeedforwardLayernorm1.wrappedValue = RMSNorm(
                dimensions: config.hiddenSize, eps: config.rmsNormEps)
            self._preFeedforwardLayernorm2.wrappedValue = RMSNorm(
                dimensions: config.hiddenSize, eps: config.rmsNormEps)
            self._postFeedforwardLayernorm2.wrappedValue = RMSNorm(
                dimensions: config.hiddenSize, eps: config.rmsNormEps)
        }

        if hiddenSizePerLayerInput > 0 {
            self._perLayerInputGate.wrappedValue = Linear(
                config.hiddenSize, hiddenSizePerLayerInput, bias: false)
            self._perLayerProjection.wrappedValue = Linear(
                hiddenSizePerLayerInput, config.hiddenSize, bias: false)
            self._postPerLayerInputNorm.wrappedValue = RMSNorm(
                dimensions: config.hiddenSize, eps: config.rmsNormEps)
        }

        self._layerScalar.wrappedValue = MLXArray.ones([1], dtype: .float16)

        super.init()
    }

    public func callAsFunction(
        _ x: MLXArray,
        mask: MLXFast.ScaledDotProductAttentionMaskMode? = nil,
        cache: KVCache? = nil,
        perLayerInput: MLXArray? = nil,
        sharedKV: (MLXArray, MLXArray)? = nil,
        positionOffset: Gemma4.PositionOffset? = nil,
        v2SharedSource: (any CBv2AttendingLayerCache)? = nil,
        outputTailRows: Int? = nil,
        useLastQueryPrefill: Bool = false,
        isExpertPrefill: Bool = false
    ) -> (MLXArray, (MLXArray, MLXArray), Gemma4.PositionOffset) {
        // Prompt-path narrowing (CBv2 only): attention and every K/V write
        // still cover the full chunk; only the token-local work AFTER
        // attention is restricted to the trailing rows CBv2 actually reads.
        let outputStart: Int
        if let outputTailRows {
            precondition(outputTailRows > 0, "Gemma4: output tail must retain at least one row")
            precondition(
                (cache as? (any CBv2AttendingLayerCache)) != nil,
                "Gemma4: output-tail narrowing is only valid for CBv2 attention")
            outputStart = max(0, x.dim(1) - outputTailRows)
        } else {
            outputStart = 0
        }
        if useLastQueryPrefill {
            precondition(
                outputTailRows == 1 && outputStart == x.dim(1) - 1,
                "Gemma4: last-query prefill retains exactly one output row")
        }

        let residual = outputStart > 0 ? x[0..., outputStart..., 0...] : x
        let activePerLayerInput: MLXArray?
        if let perLayerInput, outputStart > 0 {
            activePerLayerInput = perLayerInput[0..., outputStart..., 0...]
        } else {
            activePerLayerInput = perLayerInput
        }

        let h = inputLayernorm(x)
        let (attnOut, kvPair, attnPositionOffset) = selfAttn(
            h, mask: mask, cache: cache, sharedKV: sharedKV, positionOffset: positionOffset,
            v2SharedSource: v2SharedSource, outputStart: outputStart,
            useLastQueryPrefill: useLastQueryPrefill)
        let postAttn = postAttentionLayernorm(attnOut)
        var out = residual + postAttn

        let residual2 = out

        if isMoE,
            let router,
            let experts,
            let postFeedforwardLayernorm1,
            let preFeedforwardLayernorm2,
            let postFeedforwardLayernorm2
        {
            // Dense + sparse branches in parallel, summed into one residual.
            var h1 = preFeedforwardLayernorm(out)
            h1 = mlp(h1)
            h1 = postFeedforwardLayernorm1(h1)

            let (topKIndices, topKWeights) = router(out)
            var h2 = preFeedforwardLayernorm2(out)
            h2 = experts(
                h2,
                topKIndices: topKIndices,
                topKWeights: topKWeights,
                isExpertPrefill: isExpertPrefill)
            h2 = postFeedforwardLayernorm2(h2)

            out = h1 + h2
        } else {
            out = preFeedforwardLayernorm(out)
            out = mlp(out)
        }

        out = postFeedforwardLayernorm(out)
        out = residual2 + out

        // PLE gating
        if let gate = perLayerInputGate,
            let proj = perLayerProjection,
            let norm = postPerLayerInputNorm,
            let perLayerInput = activePerLayerInput
        {
            let residual3 = out
            var g = gate(out)
            g = gemma4SafeGeluApproximate(g)
            g = g * perLayerInput
            g = proj(g)
            g = norm(g)
            out = residual3 + g
        }

        out = out * layerScalar

        return (out, kvPair, attnPositionOffset)
    }
}

// MARK: - Text Model

/// Inner Gemma 4 trunk: embeddings + per-layer-input (PLE) + 35 decoder
/// layers + final norm. Public so the Gemma 4 MTP drafter in
/// `Gemma4MTP` can build its own 4-layer kv-shared trunk; not
/// intended as a user-facing model — use `Gemma4TextModel` for
/// standalone inference.
public class Gemma4TextModelInner: Module {
    let config: Gemma4TextConfiguration
    let embedScale: Float
    let hiddenSizePerLayerInput: Int

    @ModuleInfo(key: "embed_tokens") public var embedTokens: Embedding
    @ModuleInfo(key: "layers") public var layers: [Gemma4DecoderLayer]
    @ModuleInfo public var norm: RMSNorm

    // Per-layer embeddings (PLE)
    @ModuleInfo(key: "embed_tokens_per_layer") var embedTokensPerLayer: Embedding?
    @ModuleInfo(key: "per_layer_model_projection") fileprivate var perLayerModelProjection: ScaledLinear?
    @ModuleInfo(key: "per_layer_projection_norm") var perLayerProjectionNorm: RMSNorm?

    // KV sharing mapping: for each layer, which earlier layer provides KVs
    let previousKvs: [Int]
    let firstKvSharedLayerIdx: Int

    /// Index of the last non-shared full-attention layer (-1 if none).
    /// Used by the shared-KV capture hook for the MTP drafter.
    let lastFullAttentionNonSharedIdx: Int
    let lastSlidingAttentionNonSharedIdx: Int

    public init(
        _ config: Gemma4TextConfiguration, forceSharedKV: Bool = false,
        fuseWeightedUnsort: Bool = false
    ) {
        self.config = config
        self.embedScale = Float(config.hiddenSize).squareRoot()
        self.hiddenSizePerLayerInput = config.hiddenSizePerLayerInput

        self._embedTokens.wrappedValue = Embedding(
            embeddingCount: config.vocabSize, dimensions: config.hiddenSize)
        self._layers.wrappedValue = (0 ..< config.numHiddenLayers).map {
            Gemma4DecoderLayer(
                config, layerIdx: $0, forceSharedKV: forceSharedKV,
                fuseWeightedUnsort: fuseWeightedUnsort)
        }
        self._norm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)

        // PLE
        if config.hiddenSizePerLayerInput > 0 {
            self._embedTokensPerLayer.wrappedValue = Embedding(
                embeddingCount: config.vocabSizePerLayerInput,
                dimensions: config.numHiddenLayers * config.hiddenSizePerLayerInput)
            self._perLayerModelProjection.wrappedValue = ScaledLinear(
                inFeatures: config.hiddenSize,
                outFeatures: config.numHiddenLayers * config.hiddenSizePerLayerInput,
                scalar: pow(Float(config.hiddenSize), -0.5))
            self._perLayerProjectionNorm.wrappedValue = RMSNorm(
                dimensions: config.hiddenSizePerLayerInput, eps: config.rmsNormEps)
        }

        // Build KV-sharing map
        self.firstKvSharedLayerIdx = config.numHiddenLayers - config.numKvSharedLayers
        var kvMap = Array(0 ..< config.numHiddenLayers)
        if config.numKvSharedLayers > 0 {
            // Find the last non-shared layer of each type
            var lastByType = [String: Int]()
            for i in 0 ..< firstKvSharedLayerIdx {
                lastByType[config.layerTypes[i]] = i
            }
            // Shared layers reference the last non-shared layer of the same type
            for j in firstKvSharedLayerIdx ..< config.numHiddenLayers {
                if let prev = lastByType[config.layerTypes[j]] {
                    kvMap[j] = prev
                }
            }
        }
        self.previousKvs = kvMap

        // Capture indices for MTP drafter: the last layer of each type that
        // still has its own K/V (not shared from an earlier layer).
        let firstShared = self.firstKvSharedLayerIdx
        var lastFull = -1
        var lastSliding = -1
        for i in 0 ..< firstShared {
            if config.layerTypes[i] == "full_attention" { lastFull = i }
            if config.layerTypes[i] == "sliding_attention" { lastSliding = i }
        }
        self.lastFullAttentionNonSharedIdx = lastFull
        self.lastSlidingAttentionNonSharedIdx = lastSliding

        super.init()
    }
    public func callAsFunction(
        _ inputs: MLXArray,
        cache: [KVCache]? = nil,
        captureHook: ((Int, (MLXArray, MLXArray)) -> Void)? = nil,
        inputEmbedding: MLXArray? = nil,
        imageTokenMask: MLXArray? = nil
    ) -> MLXArray {
        // Callers may hand rank-1 token ids ([N] on cache-reuse turns, e.g.
        // the deprecated TokenIterator API) — the deleted inline VLM twin
        // normalized the whole multimodal tuple before any dimension read.
        // Expand tokens, supplied embeddings, and the visual mask together
        // so they continue to agree on [B, L].
        let rankOneInputs = inputs.ndim == 1
        let inputs = rankOneInputs ? inputs.expandedDimensions(axis: 0) : inputs
        let inputEmbedding =
            rankOneInputs && inputEmbedding?.ndim == 2
            ? inputEmbedding?.expandedDimensions(axis: 0) : inputEmbedding
        let imageTokenMask =
            rankOneInputs && imageTokenMask?.ndim == 1
            ? imageTokenMask?.expandedDimensions(axis: 0) : imageTokenMask
        return forwardTrunk(
            inputs, cache: cache, captureHook: captureHook, capturePreNorm: false,
            inputEmbedding: inputEmbedding, imageTokenMask: imageTokenMask
        ).postNorm
    }

    /// CBv2 prompt-forward entry point. Keeping the scheduled-prefill
    /// specializations behind their own entry point means legacy forwards,
    /// compiled [B, 1] decode, and MTP verification can never reach them.
    fileprivate func cbv2Prefill(
        _ inputs: MLXArray,
        cache: [KVCache]?,
        inputEmbedding: MLXArray?
    ) -> MLXArray {
        forwardTrunk(
            inputs, cache: cache, captureHook: nil, capturePreNorm: false,
            inputEmbedding: inputEmbedding, schedulePrefill: true
        ).postNorm
    }

    /// Variant that ALSO returns the pre-norm last-layer hidden state.
    /// The MTP drafter's `pre_projection` was trained against the pre-norm
    /// hidden (HF captures `hidden_states` at the decoder-layer boundary,
    /// BEFORE `model.norm`); the LM head consumes the post-norm hidden.
    /// The non-MTP path goes through `callAsFunction`.
    public func callCapturingPreNorm(
        _ inputs: MLXArray,
        cache: [KVCache]? = nil,
        captureHook: ((Int, (MLXArray, MLXArray)) -> Void)? = nil
    ) -> (postNorm: MLXArray, preNorm: MLXArray) {
        // Same rank-1 defense as `callAsFunction`: token ids may arrive as
        // [N] on cache-reuse turns; forwardTrunk assumes [B, L].
        let inputs = inputs.ndim == 1 ? inputs.expandedDimensions(axis: 0) : inputs
        let r = forwardTrunk(
            inputs, cache: cache, captureHook: captureHook, capturePreNorm: true)
        return (r.postNorm, r.preNorm!)
    }

    private func forwardTrunk(
        _ inputs: MLXArray,
        cache: [KVCache]?,
        captureHook: ((Int, (MLXArray, MLXArray)) -> Void)?,
        capturePreNorm: Bool,
        inputEmbedding: MLXArray? = nil,
        imageTokenMask: MLXArray? = nil,
        schedulePrefill: Bool = false
    ) -> (postNorm: MLXArray, preNorm: MLXArray?) {
        let shapeCall = CBv2ForwardShapeObservation.isActive
            ? CBv2ForwardShapeObservation.beginTarget(liveBatchRows: inputs.dim(0), sequenceWidth: inputs.dim(1)) : nil
        defer { shapeCall?.end() }
        // Vision prefill (mirrors the inline VLM twin `TextModel.callAsFunction`):
        // `inputEmbedding` — the scaled text embeddings with image soft-token
        // embeddings spliced at placeholder positions — replaces the trunk's
        // own lookup; token ids still feed the per-layer embeddings (PLE)
        // below. nil keeps the text path byte-identical.
        var h: MLXArray
        if let inputEmbedding {
            h = inputEmbedding.ndim == 2 ? inputEmbedding.expandedDimensions(axis: 0) : inputEmbedding
        } else {
            h = embedTokens(inputs) * embedScale
        }

        // Compute per-layer inputs (PLE)
        var perLayerInputs: [MLXArray?]
        if hiddenSizePerLayerInput > 0,
            let embedPerLayer = embedTokensPerLayer,
            let modelProj = perLayerModelProjection,
            let projNorm = perLayerProjectionNorm
        {
            // Token-based PLE
            let tokenPLE =
                embedPerLayer(inputs)
                * Float(config.hiddenSizePerLayerInput).squareRoot()

            // [B, L, numLayers * hiddenSizePerLayerInput] -> [B, L, numLayers, hiddenSizePerLayerInput]
            let reshapedTokenPLE = tokenPLE.reshaped(
                tokenPLE.dim(0), tokenPLE.dim(1),
                config.numHiddenLayers, config.hiddenSizePerLayerInput)

            // Model projection PLE
            let modelPLE = modelProj(h).reshaped(
                h.dim(0), h.dim(1),
                config.numHiddenLayers, config.hiddenSizePerLayerInput)
            let normedModelPLE = projNorm(modelPLE)

            // Combine: (model_proj + token_embed) * 2^{-0.5}
            let perLayerInputScale = pow(Float(2.0), -0.5)
            let combined = (normedModelPLE + reshapedTokenPLE) * perLayerInputScale

            perLayerInputs = (0 ..< config.numHiddenLayers).map { i in
                combined[.ellipsis, i, 0...]
            }
        } else {
            perLayerInputs = Array(repeating: nil, count: config.numHiddenLayers)
        }

        // Extend cache array for shared layers (which get nil caches)
        var fullCache: [KVCache?]
        if let cache {
            fullCache = cache.map { Optional($0) }
            while fullCache.count < config.numHiddenLayers {
                fullCache.append(nil)
            }
        } else {
            fullCache = Array(repeating: nil, count: config.numHiddenLayers)
        }

        // ContinuousBatchingV2 detection: v2 layer caches own attention AND
        // masking, so the trunk builds no masks at all on that path (there is
        // no padding and no shared frontier to mask). In v2 mode every layer
        // (including KV-shared ones) has a cache object.
        let isCBv2 = fullCache.contains { ($0 as? (any CBv2AttendingLayerCache)) != nil }

        // Build masks: one per attention type (legacy path only). "vision"
        // overlays bidirectional access within visual spans. "all" preserves
        // Gemma4's fully bidirectional prefill by symmetrizing both global and
        // sliding causal masks. Either mode needs a materialized array; ordinary
        // text and single-token decode retain the symbolic causal fast path.
        var maskByType = [String: MLXFast.ScaledDotProductAttentionMaskMode]()
        if !isCBv2 {
            let useBidirectionalVision =
                imageTokenMask != nil && config.useBidirectionalAttention == "vision"
                && h.dim(1) > 1
            let useBidirectionalAll =
                config.useBidirectionalAttention == "all" && h.dim(1) > 1
            let forceArrayMask = useBidirectionalVision || useBidirectionalAll
            for (i, layer) in layers.enumerated() {
                let lt = layer.layerType
                if maskByType[lt] == nil {
                    var mask: MLXFast.ScaledDotProductAttentionMaskMode
                    if lt == "sliding_attention" {
                        mask = createAttentionMask(
                            h: h, cache: fullCache[i], windowSize: config.slidingWindow,
                            returnArray: forceArrayMask)
                    } else {
                        mask = createAttentionMask(
                            h: h, cache: fullCache[i], windowSize: nil,
                            returnArray: forceArrayMask)
                    }
                    if useBidirectionalVision, let imageTokenMask {
                        mask = gemma4TextOverlayBidirectionalVision(
                            mask, isVision: imageTokenMask)
                    } else if useBidirectionalAll {
                        mask = gemma4TextSymmetrizeMask(mask)
                    }
                    maskByType[lt] = mask
                }
            }
        }

        // Forward through layers, tracking intermediate KV pairs for sharing
        var intermediates = [(kv: (MLXArray, MLXArray)?, positionOffset: Gemma4.PositionOffset?)](
            repeating: (nil, nil), count: config.numHiddenLayers)

        for (idx, layer) in layers.enumerated() {
            let prevIdx = previousKvs[idx]
            let sharedKV = intermediates[prevIdx].kv
            let sharedPositionOffset = intermediates[prevIdx].positionOffset

            // CBv2: KV-shared layers attend by borrowing the SOURCE layer's
            // cache object (attendBorrowing) instead of consuming raw K/V
            // tensors. Thread the source cache alongside the source's
            // captured (pre-update) position offsets.
            let v2SharedSource: (any CBv2AttendingLayerCache)? =
                isCBv2 && prevIdx != idx
                ? fullCache[prevIdx] as? (any CBv2AttendingLayerCache) : nil

            let mask = maskByType[layer.layerType]
            // Prompt-path specializations, final layer only. Every earlier
            // layer runs the full chunk unchanged because later positions'
            // K/V depend on it.
            let policy = gemma4LayerPrefillPolicy(
                config, globalLayerIndex: idx, finalOutputLayerIndex: layers.count - 1,
                ownsFinalOutput: true,
                schedulePrefill: schedulePrefill, isCBv2: isCBv2,
                batchSize: h.dim(0), sequenceLength: h.dim(1),
                inputSequenceLength: inputs.dim(1),
                hasLastQueryCache: fullCache[idx] is any CBv2LastQueryPrefillLayerCache)
            let (out, kvPair, positionOffset) = layer(
                h,
                mask: mask,
                cache: fullCache[idx],
                perLayerInput: perLayerInputs[idx],
                sharedKV: sharedKV,
                positionOffset: sharedPositionOffset,
                v2SharedSource: v2SharedSource,
                outputTailRows: policy.outputTailRows,
                useLastQueryPrefill: policy.useLastQuery,
                // The retained pair is a CBv2 production-prefill optimization.
                // Ordinary direct forwards keep the established reduction;
                // enabling it there regressed the raw-prefill control without
                // affecting the serving path selected by the benchmark.
                isExpertPrefill: policy.expertPrefill
            )
            h = out
            intermediates[idx] = (kvPair, positionOffset)
            captureHook?(idx, kvPair)

            if policy.submitIntermediate {
                asyncEval(h)
                CBv2StepProfiler.recordEvent("v2.gemma4.prefill.chunk_eval")
            }
        }

        let postNorm = norm(h)
        return (postNorm, capturePreNorm ? h : nil)
    }
}

// MARK: - Bidirectional vision attention overlay (mirror of the VLM twin)

/// Per-token block id for vision spans: each contiguous run of vision tokens
/// shares an id, non-vision tokens get -1. Exact mirror of
/// `gemma4VisionBlockIds` in Libraries/MLXVLM/Models/Gemma4.swift (Python
/// `_block_sequence_ids_for_mask`).
private func gemma4TextVisionBlockIds(_ isVision: MLXArray) -> MLXArray {
    let length = isVision.dim(1)
    let leading = MLXArray.zeros([isVision.dim(0), 1], dtype: .bool)
    let prev = concatenated([leading, isVision[0..., ..<(length - 1)]], axis: 1)
    let starts = logicalAnd(isVision, logicalNot(prev))
    let groupIds = cumsum(starts.asType(.int32), axis: 1) - 1
    return MLX.where(isVision, groupIds, MLXArray(Int32(-1)))
}

/// Overlay blockwise bidirectional attention for vision-token spans onto a
/// boolean causal mask (true = attend): tokens in the same image block
/// attend each other in BOTH directions. Exact mirror of
/// `gemma4BidirectionalVisionMask` (Python
/// `_apply_blockwise_bidirectional_overlay`).
private func gemma4TextBidirectionalVisionMask(
    _ baseMask: MLXArray, isVision: MLXArray
) -> MLXArray {
    let blockIds = gemma4TextVisionBlockIds(isVision)
    let qBlocks = expandedDimensions(blockIds, axis: -1)  // [B, L, 1]
    let kBlocks = expandedDimensions(blockIds, axis: -2)  // [B, 1, L]
    var sameBlock = logicalAnd(qBlocks .!= MLXArray(Int32(-1)), qBlocks .== kBlocks)  // [B, L, L]
    // Cached (chunked) prefill: `baseMask` covers ALL key columns
    // (`offset + L`) while `sameBlock` only describes the current window's
    // L columns. Left-pad with `false` so the overlay lands on the LAST L
    // key columns — cached keys stay causal. Callers must never split an
    // image block across the cache boundary (the CBv2 scheduler snaps
    // chunks to block edges; whole-prompt prefill has offset 0), or the
    // overlay could not see the cached half of the block (PR#63 review).
    let L = isVision.dim(1)
    let keyColumns = baseMask.dim(-1)
    if keyColumns > L {
        let pad = MLXArray.zeros([sameBlock.dim(0), L, keyColumns - L], dtype: .bool)
        sameBlock = concatenated([pad, sameBlock], axis: -1)  // [B, L, offset+L]
    }
    return logicalOr(baseMask, expandedDimensions(sameBlock, axis: 1))  // -> [B, 1, L, offset+L]
}

/// If `mode` carries a boolean array mask, overlay the vision bidirectional
/// attention; pass other modes (`.causal`, `.none`) through unchanged.
private func gemma4TextOverlayBidirectionalVision(
    _ mode: MLXFast.ScaledDotProductAttentionMaskMode, isVision: MLXArray
) -> MLXFast.ScaledDotProductAttentionMaskMode {
    switch mode {
    case .array(let maskArray):
        return .array(gemma4TextBidirectionalVisionMask(maskArray, isVision: isVision))
    default:
        return mode
    }
}

/// Symmetrize the materialized causal/windowed mask for
/// `use_bidirectional_attention == "all"`. Global layers become fully
/// bidirectional; sliding layers remain bounded by their symmetric window.
func gemma4TextSymmetrizeMask(
    _ mode: MLXFast.ScaledDotProductAttentionMaskMode
) -> MLXFast.ScaledDotProductAttentionMaskMode {
    switch mode {
    case .array(let maskArray):
        let queryCount = maskArray.dim(-2)
        let keyCount = maskArray.dim(-1)
        guard keyCount >= queryCount else { return mode }
        let prefixCount = keyCount - queryCount
        let current = maskArray[.ellipsis, prefixCount...]
        let symmetricCurrent = logicalOr(current, current.swappedAxes(-1, -2))
        guard prefixCount > 0 else { return .array(symmetricCurrent) }
        // Cached columns already describe the exact visible prefix for every
        // current query. Only the trailing current-query square has a valid
        // transpose; keep the rectangular prefix unchanged.
        return .array(concatenated(
            [maskArray[.ellipsis, ..<prefixCount], symmetricCurrent], axis: -1))
    default:
        return mode
    }
}

// MARK: - Public Model

public class Gemma4TextModel: Module, LLMModel, KVCacheDimensionProvider {
    public let vocabularySize: Int
    public let kvHeads: [Int]

    fileprivate let config: Gemma4TextConfiguration
    let model: Gemma4TextModelInner
    let fuseWeightedUnsort: Bool

    /// Read-only accessor for the underlying text configuration. Needed by
    /// `Gemma4AssistantDraftModel` for its bind-time compatibility checks.
    public var configuration: Gemma4TextConfiguration { config }

    /// Process request and resolved immutable eligibility for production
    /// benchmark provenance. A truthy request stays ineffective unless the
    /// checkpoint is the exact supported Gemma 4 geometry *and* carries the
    /// safe expert-QMM quantization contract, because weighted unsort is only
    /// a win as half of the coupled weighted + safe-R1 pair.
    public var weightedExpertUnsortRequested: Bool { gemma4FusedWeightedUnsortRequested }
    public var weightedExpertUnsortEffective: Bool { fuseWeightedUnsort }

    /// Whether this checkpoint satisfies everything the safe Gemma 4
    /// expert-QMM selector can decide from configuration: the exact expert
    /// topology and the 4-bit / group-size-64 quantization contract. The
    /// runtime feature request, AOT capability, and NAX precedence are
    /// reported separately by MLX. Identical to the predicate gating weighted
    /// unsort, so the pair can never report or run half-applied.
    public var expertQMMGeometryEligible: Bool {
        gemma4SupportsCoupledExpertOptimizations(config)
    }

    /// Canonical decoder-layer roots. Wrappers whose existing LoRA adapter
    /// keys are decoder-relative use these roots without owning another tower.
    public var decoderLayers: [Module] { model.layers }

    @ModuleInfo(key: "lm_head") var lmHead: Linear?

    public init(_ config: Gemma4TextConfiguration) {
        let fuseWeightedUnsort = gemma4ShouldFuseWeightedUnsort(config)
        self.config = config
        self.vocabularySize = config.vocabSize
        // Per-layer KV head counts must agree with `Gemma4Attention.init`:
        // full layers use `num_global_key_value_heads` when present (whether
        // or not k_eq_v is enabled), sliding layers the sliding count.
        self.kvHeads = (0 ..< config.numHiddenLayers).map { idx in
            let layerType = idx < config.layerTypes.count ? config.layerTypes[idx] : "sliding_attention"
            return layerType == "full_attention"
                ? (config.numGlobalKeyValueHeads ?? config.numKeyValueHeads)
                : config.numKeyValueHeads
        }
        self.fuseWeightedUnsort = fuseWeightedUnsort
        self.model = Gemma4TextModelInner(
            config,
            fuseWeightedUnsort: fuseWeightedUnsort)

        if !config.tieWordEmbeddings {
            self._lmHead.wrappedValue = Linear(config.hiddenSize, config.vocabSize, bias: false)
        }
    }

    public func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws
        -> PrepareResult
    {
        // Fully bidirectional prompt states require whole-prompt visibility.
        // Returning the complete prompt lets TokenIterator evaluate it once.
        guard config.useBidirectionalAttention != "all" else {
            return .tokens(input.text)
        }

        let prefillStepSize = windowSize ?? 512
        var remaining = input.text
        while remaining.tokens.size > prefillStepSize {
            let chunk = remaining[.newAxis, ..<prefillStepSize]
            _ = self(chunk, cache: cache.isEmpty ? nil : cache, state: nil)
            eval(cache)
            remaining = remaining[prefillStepSize...]
        }
        return .tokens(remaining)
    }

    public func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        let hidden = model(inputs, cache: cache)
        return applyLMHead(hidden)
    }

    /// Vision forward (mirror of the VLM wrapper's
    /// `languageModel(tokens, inputEmbedding:cache:imageTokenMask:)` call):
    /// `inputEmbedding` replaces the trunk's own embedding lookup (spliced
    /// image soft tokens; token ids still feed the PLE side inputs), and
    /// `imageTokenMask` ([B, L] bool) enables the blockwise bidirectional
    /// overlay on the LEGACY mask path (v2 layer caches own their masks and
    /// ignore it). Both nil ⇒ byte-identical to `callAsFunction(_:cache:)`.
    public func callAsFunction(
        _ inputs: MLXArray, inputEmbedding: MLXArray?, cache: [KVCache]?,
        imageTokenMask: MLXArray? = nil
    ) -> MLXArray {
        applyLMHead(
            model(
                inputs, cache: cache, inputEmbedding: inputEmbedding,
                imageTokenMask: imageTokenMask))
    }

    /// Apply the LM head (tied embedding or explicit `lm_head`) plus the
    /// configured final-logit softcap. Pure function of the post-norm hidden.
    func applyLMHead(_ hidden: MLXArray) -> MLXArray {
        var out: MLXArray
        if let lmHead {
            out = lmHead(hidden)
        } else {
            out = model.embedTokens.asLinear(hidden)
        }
        // The VLM omission profile uses zero to represent the former optional
        // softcap's nil/disabled state.
        if config.finalLogitSoftcapping > 0 {
            out = gemma4CompiledLogitSoftcap(
                out, MLXArray(config.finalLogitSoftcapping))
        }
        return out
    }

    /// Compute the scaled input embedding for `tokens`, matching what the
    /// inner trunk does in its first step (`embedTokens(inputs) * embedScale`).
    /// Used by `Gemma4AssistantDraftModel` as the "target embedding" input
    /// when building its drafter-step input `[target_embed(last_token), last_hidden]`.
    public func embedTokensForDrafter(_ tokens: MLXArray) -> MLXArray {
        model.embedTokens(tokens) * Float(config.hiddenSize).squareRoot()
    }

    /// Internal helper for Gemma4CaptureHookTests. Not part of the public API.
    internal func _testCallInner(
        _ inputs: MLXArray,
        cache: [KVCache],
        captureHook: ((Int, (MLXArray, MLXArray)) -> Void)? = nil
    ) -> MLXArray {
        model(inputs, cache: cache, captureHook: captureHook)
    }

    @_spi(Diagnostics)
    public func diagnosticLayer0Projections(tokens: [Int]) throws -> Gemma4Layer0ProjectionDiagnostic {
        guard tokens.count == 2, tokens.allSatisfy({ (0..<vocabularySize).contains($0) }) else {
            throw Gemma4Layer0ProjectionDiagnostic.Failure.invalidTokenPair
        }
        guard config.hiddenSizePerLayerInput == 0, let layer = model.layers.first,
            !layer.selfAttn.usesSharedKV, !layer.selfAttn.useKeqV else {
            throw Gemma4Layer0ProjectionDiagnostic.Failure.unsupportedLayer
        }
        guard let query = layer.selfAttn.qProj as? QuantizedLinear,
            let key = layer.selfAttn.kProj as? QuantizedLinear,
            let value = layer.selfAttn.vProj as? QuantizedLinear else {
            throw Gemma4Layer0ProjectionDiagnostic.Failure.expectedQuantizedProjections
        }
        let projections = ["q": query, "k": key, "v": value]
        var tensors: [String: MLXArray] = [:]
        for width in 1...2 {
            let input = MLXArray(tokens.prefix(width).map(Int32.init)).reshaped([1, width])
            let embedded = model.embedTokens(input) * model.embedScale
            let normalized = layer.inputLayernorm(embedded)
            tensors["m\(width).embedding"] = embedded
            tensors["m\(width).normalized"] = normalized
            for (name, projection) in projections {
                tensors["m\(width).\(name)"] = projection(normalized)
            }
        }
        var parameters: [String: MLXArray] = ["input_layernorm.weight": layer.inputLayernorm.weight]
        var quantization: [String: Gemma4Layer0ProjectionDiagnostic.Quantization] = [:]
        for (name, projection) in projections {
            for (parameter, tensor) in projection.parameters().flattened() {
                parameters["\(name).\(parameter)"] = tensor
            }
            quantization[name] = .init(groupSize: projection.groupSize, bits: projection.bits,
                mode: String(describing: projection.mode))
        }
        return .init(tensors: tensors, parameters: parameters, quantization: quantization)
    }

    /// Parse the layer index out of a weight key like
    /// `"model.layers.15.self_attn.k_proj.weight"`. Returns nil if the key
    /// doesn't match the expected `...layers.<N>...` pattern.
    private func extractLayerIdx(from key: String) -> Int? {
        guard let layersRange = key.range(of: "layers.") else { return nil }
        let after = key[layersRange.upperBound...]
        let end = after.firstIndex(of: ".") ?? after.endIndex
        return Int(after[..<end])
    }


    public func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        var sanitized = [String: MLXArray]()
        for (k, v) in weights {
            // Skip vision/audio/rotary/quantization-range weights.
            if k.contains("self_attn.rotary_emb")
                || k.contains("input_max")
                || k.contains("input_min")
                || k.contains("output_max")
                || k.contains("output_min")
            {
                continue
            }

            // Skip k_proj/v_proj/k_norm/v_norm weights for layers that
            // borrow K/V from an earlier non-shared layer (num_kv_shared_layers
            // tail). Our `Gemma4Attention.init` doesn't allocate these modules
            // for shared-KV layers, so the checkpoint's copies would fail the
            // strict `update(parameters:verify:.all)` check.
            if let layerIdx = extractLayerIdx(from: k),
                config.layerUsesSharedKV(layerIdx: layerIdx),
                k.contains(".self_attn.k_proj.")
                    || k.contains(".self_attn.v_proj.")
                    || k.contains(".self_attn.k_norm.")
                    || k.contains(".self_attn.v_norm.")
            {
                continue
            }

            // Some 26B-A4B checkpoints ship one raw expert `gate_up_proj`
            // tensor plus `down_proj`. The ordinary SwitchGLU topology owns
            // split projections, so normalize the packed tensor here.
            if k.hasSuffix(".experts.gate_up_proj") {
                let base = String(k.dropLast(".gate_up_proj".count))
                let parts = MLX.split(v, parts: 2, axis: -2)
                sanitized["\(base).switch_glu.gate_proj.weight"] = parts[0]
                sanitized["\(base).switch_glu.up_proj.weight"] = parts[1]
                continue
            }

            if k.hasSuffix(".experts.down_proj") {
                let base = String(k.dropLast(".down_proj".count))
                sanitized["\(base).switch_glu.down_proj.weight"] = v
                continue
            }

            sanitized[k] = v
        }
        return sanitized
    }

    public func newCache(parameters: GenerateParameters?) -> [any KVCache] {
        let firstKvShared = config.numHiddenLayers - config.numKvSharedLayers

        var caches = [any KVCache]()
        for i in 0 ..< firstKvShared {
            if config.layerTypes[i] == "full_attention" {
                if let maxKVSize = parameters?.maxKVSize {
                    caches.append(RotatingKVCache(maxSize: maxKVSize, keep: 4))
                } else {
                    caches.append(StandardKVCache())
                }
            } else {
                caches.append(RotatingKVCache(maxSize: config.slidingWindow, keep: 0))
            }
        }
        return caches
    }
}

// MARK: - LoRA

extension Gemma4TextModel: LoRAModel {
    public var loraLayers: [Module] {
        model.layers.map { $0.selfAttn }
    }
}

// MARK: - ContinuousBatchingV2

extension Gemma4TextConfiguration {
    /// Per-layer attention structure for the CBv2 engine, derived purely
    /// from this configuration (invariant 11: model structure is data).
    /// Matches `Gemma4Attention.init` / `Gemma4TextModelInner.previousKvs`
    /// layer for layer.
    public var cbv2LayerKinds: [CBv2LayerKind] {
        CBv2LayerKindDerivation.gemma4LayerKinds(
            layerTypes: layerTypes,
            slidingWindow: slidingWindow,
            numKvSharedLayers: numKvSharedLayers,
            headDim: headDim,
            globalHeadDim: globalHeadDim,
            numAttentionHeads: numAttentionHeads,
            numKeyValueHeads: numKeyValueHeads,
            numGlobalKeyValueHeads: numGlobalKeyValueHeads,
            isBidirectional: useBidirectionalAttention == "all"
        )
    }
}

extension Gemma4TextModel {
    /// Per-layer CBv2 attention structure for this model (one entry per
    /// hidden layer, including the trailing KV-shared block).
    public var cbv2LayerKinds: [CBv2LayerKind] {
        config.cbv2LayerKinds
    }

    /// Effective layer interval for scheduled CBv2 prompt submissions.
    /// Zero means the optimization is disabled and the trunk has only its
    /// caller's final graph submission.
    public var cbv2PrefillChunkEvalInterval: Int {
        gemma4PrefillChunkEvalLayers
    }

    public enum CBv2CompatibilityError: Error, Equatable, CustomStringConvertible {
        case fullyBidirectionalAttentionUnsupported

        public var description: String {
            switch self {
            case .fullyBidirectionalAttentionUnsupported:
                return "Gemma4 CBv2 does not support use_bidirectional_attention=all because split prefill cannot preserve whole-prompt visibility"
            }
        }
    }

    /// Build the per-layer CBv2 attending caches for this model: one
    /// `CBv2AttendingLayerCache` per hidden layer (KV-shared layers get a
    /// cache object too — it owns no storage and serves `attendBorrowing`).
    ///
    /// The concrete layer-cache classes are owned by the CBv2 core runtime;
    /// `makeLayerCache` is the injection point (typically wrapping a
    /// `CBv2KVBackend`). This model file codes purely against the contract.
    public func newCacheV2(
        makeLayerCache: (_ layerIndex: Int, _ kind: CBv2LayerKind) throws ->
            any CBv2AttendingLayerCache
    ) throws -> [any CBv2AttendingLayerCache] {
        guard config.useBidirectionalAttention != "all" else {
            throw CBv2CompatibilityError.fullyBidirectionalAttentionUnsupported
        }
        return try cbv2LayerKinds.enumerated().map { index, kind in
            try makeLayerCache(index, kind)
        }
    }
}

// MARK: - ContinuousBatchingV2 prompt-only output narrowing

/// CBv2 consumes only the final prompt position, so the public
/// `LanguageModel` forward contract stays unchanged while the engine's
/// prompt path skips the vocabulary projection for discarded positions:
/// intermediate chunks project nothing, and the frontier chunk projects one
/// hidden row. Attention, multimodal span masks, positions, and every K/V
/// write still cover the full chunk.
extension Gemma4TextModel: CBv2LanguageModelPrefillForwardable {

    /// The Gemma trunk is shape-generic over `[B, L]`, and the CBv2
    /// attention dispatch handles a rectangular `B > 1, L > 1` prompt batch
    /// by attending each row against its OWN KV (the same per-row path a
    /// `[1, chunk]` call takes), so a packed row is bit-identical to running
    /// alone. The engine still requires the cache provider to vouch for row
    /// independence before it packs anything.
    public var cbv2SupportsPackedPrefill: Bool { true }
    public var cbv2SupportsPackedMultimodalPrefill: Bool { true }

    public func cbv2Prefill(
        _ inputs: MLXArray,
        inputEmbedding: MLXArray?,
        cache: [KVCache]?,
        requirement: CBv2PrefillRequirement
    ) -> MLXArray {
        let hidden = model.cbv2Prefill(
            inputs, cache: cache, inputEmbedding: inputEmbedding)
        switch requirement {
        case .evaluationOnly:
            // Small handle whose graph depends on the whole trunk — forcing
            // it commits every layer's K/V write for this chunk.
            return hidden[0..., -1, 0 ..< 1]
        case .lastPositionLogits:
            return applyLMHead(hidden[0..., -1, 0...])
        }
    }
}

// MARK: - ContinuousBatchingV2 multimodal (vision prefill)

/// The CBv2 engine's embedding-spliced prefill surface
/// (`CBv2SteppableLanguageModelAdapter` forwards through this). The v2
/// attention branch is reached exactly as for token forwards — the layer
/// caches detected in `cache` own attention AND masking (the engine binds
/// the span-mask context on them) — only the embedding source differs.
/// Positions, KV sharing, and dual RoPE are untouched.
extension Gemma4TextModel: CBv2EmbeddingForwardable {

    /// Only configs whose weights were trained with the bidirectional
    /// image-span attention may serve CBv2 vision spans — the same gate the
    /// legacy `imageTokenMask` path applies. Text-only Gemma4 configs
    /// (nil / non-`"vision"`) reject multimodal requests at submit instead
    /// of silently serving logits under masks the weights never saw
    /// (PR#63 review).
    public var supportsVisionSpanPrefill: Bool {
        config.useBidirectionalAttention == "vision"
    }

    /// `embed(tokens) * embedScale` — exactly the trunk's pre-layer-0 hidden
    /// state, the tensor the engine splices image embeddings into (the
    /// VLM wrapper's `prepare` computes the same product before
    /// `maskedScatter`).
    public func scaledInputEmbeddings(_ inputs: MLXArray) -> MLXArray {
        model.embedTokens(inputs) * model.embedScale
    }

    public func embeddingForward(
        _ inputs: MLXArray, inputEmbedding: MLXArray, cache: [KVCache]?
    ) -> MLXArray {
        applyLMHead(model(inputs, cache: cache, inputEmbedding: inputEmbedding))
    }
}

// MARK: - ContinuousBatchingV2 MTP (speculative decoding)

/// The CBv2 engine's MTP verify surface (`CBv2MTPForwardable`): the plain
/// forward plus the PRE-norm last-decoder-layer hidden the Gemma-4 drafter
/// chains from, and the layer indices the engine snapshots for the drafter's
/// frozen KV. The logits side is numerically identical to
/// `callAsFunction(_:cache:)` — same trunk, same LM head, same softcap.
extension Gemma4TextModel: CBv2MTPForwardable {

    public var cbv2MTPCaptureLayers: CBv2MTPCaptureLayers? {
        let full = model.lastFullAttentionNonSharedIdx
        let sliding = model.lastSlidingAttentionNonSharedIdx
        guard full >= 0, sliding >= 0 else { return nil }
        return CBv2MTPCaptureLayers(full: full, sliding: sliding)
    }

    public func cbv2ForwardWithHidden(
        _ tokens: MLXArray, caches: [KVCache]
    ) -> (logits: MLXArray, lastHidden: MLXArray) {
        let (postNorm, preNorm) = model.callCapturingPreNorm(tokens, cache: caches)
        return (applyLMHead(postNorm), preNorm)
    }
}


extension Gemma4TextModel: CBv2HistoricalAttentionCheckpointProviding {
    public var cbv2SupportsHistoricalAttentionCheckpoint: Bool {
        !cbv2LayerKinds.contains(where: \.isBidirectional)
    }
}
