import Foundation

/// Report-friendly, model-aware KV quantization policy scaffolding.
///
/// This type only describes candidate policy decisions for benchmarks. It does
/// not mutate live model caches or assume a concrete quantization kernel exists.
public struct KVQuantPolicy: Codable, Sendable, Equatable {
    public static let currentVersion = "kvquant-policy-v0"

    public let policyVersion: String
    public let modelID: String
    public let modelFamily: KVQuantModelFamily
    public let candidateMode: KVQuantPolicyCandidateMode
    public let plan: KVQuantPlan
    public let summary: String
    public let reasons: [String]

    enum CodingKeys: String, CodingKey {
        case policyVersion = "policy_version"
        case modelID = "model_id"
        case modelFamily = "model_family"
        case candidateMode = "candidate_mode"
        case plan
        case summary
        case reasons
    }

    public init(modelID: String, hardware: HardwareInfo?) {
        self.init(modelID: modelID, chipFamily: hardware?.chipFamily)
    }

    public init(modelID: String, chipFamily: ChipFamily? = nil) {
        let family = Self.classify(modelID: modelID)
        let mode = Self.candidateMode(for: chipFamily)
        let recommendation = Self.recommendation(for: family, mode: mode)

        self.policyVersion = Self.currentVersion
        self.modelID = modelID
        self.modelFamily = family
        self.candidateMode = mode
        self.plan = recommendation.plan
        self.summary = recommendation.summary
        self.reasons = recommendation.reasons
    }

    public static func classify(modelID: String) -> KVQuantModelFamily {
        let normalized = normalizedModelID(modelID)

        if normalized.contains("gemma4") {
            return .gemma4
        }
        if normalized.contains("gptoss") {
            return .gptOSS
        }
        return .unknown
    }

    public static func candidateMode(for chipFamily: ChipFamily?) -> KVQuantPolicyCandidateMode {
        switch chipFamily {
        case .m1, .m2:
            return .conservative
        case .m3, .m4:
            return .normal
        case .m5:
            return .aggressiveCandidate
        case .unknown, nil:
            return .conservative
        }
    }

    private static func recommendation(
        for family: KVQuantModelFamily,
        mode: KVQuantPolicyCandidateMode
    ) -> (plan: KVQuantPlan, summary: String, reasons: [String]) {
        switch family {
        case .gemma4:
            let summary = "Gemma 4: validated KV quant engine scheme is `k8v8:g128` (8-bit affine K+V on full/global layers, group size 128; rotating/sliding caches stay fp16)."
            return (
                KVQuantPlan(
                    enabled: true,
                    layerScope: .fullAndGlobalOnly,
                    tensorTarget: .keysAndValues,
                    keyPrecision: .quantized8Bit,
                    valuePrecision: .quantized8Bit,
                    valueEncoding: .affine8,
                    quantizationStartToken: 0,
                    sinkAware: .notRequired,
                    rotatingSlidingPrecision: .fp16,
                    mtpPolicy: .disabled,
                    reportDescription: summary
                ),
                summary,
                [
                    "Gemma 4 should only quantize full/global attention layers; rotating or sliding-window layers remain fp16.",
                    "The live engine scheme is `k8v8:g128` (8-bit affine keys and values, group size 128).",
                    "This scheme passes the PPL/logits/output/NIAH gates and is wired through `KVQuantEngineScheme.gemma4K8V8G128`.",
                    "MTP is disabled until a model-specific guarded path is validated.",
                    mode.reportDescription,
                ]
            )

        case .gptOSS:
            let summary = "GPT-OSS: validated live KV quant engine scheme is `k8v8:g64:dequant` (8-bit affine K+V on full layers, group size 64; rotating/sliding caches stay fp16; dequant path preserves MLX fused sink-aware attention)."
            return (
                KVQuantPlan(
                    enabled: true,
                    layerScope: .fullOnly,
                    tensorTarget: .keysAndValues,
                    keyPrecision: .quantized8Bit,
                    valuePrecision: .quantized8Bit,
                    valueEncoding: .affine8,
                    quantizationStartToken: 0,
                    sinkAware: .required,
                    rotatingSlidingPrecision: .fp16,
                    mtpPolicy: .disabled,
                    reportDescription: summary
                ),
                summary,
                [
                    "GPT-OSS should only quantize full attention layers; rotating or sliding-window layers remain fp16.",
                    "Sink-aware handling is required; the live scheme uses DequantBatchKVCache so MLXFast.scaledDotProductAttention receives dequantized K/V and native sinks.",
                    "The live engine scheme is `k8v8:g64:dequant` (8-bit affine keys and values, group size 64).",
                    "The dequant cache stores quantized K/V for capacity while preserving the fused MLX attention path for decode.",
                    mode.reportDescription,
                ]
            )

        case .unknown:
            let summary = "Unknown model family: KV quantization disabled until a model-aware policy is added."
            return (
                KVQuantPlan(
                    enabled: false,
                    layerScope: .none,
                    tensorTarget: .none,
                    keyPrecision: .fp16,
                    valuePrecision: .fp16,
                    valueEncoding: nil,
                    quantizationStartToken: nil,
                    sinkAware: .notRequired,
                    rotatingSlidingPrecision: .fp16,
                    mtpPolicy: .disabled,
                    reportDescription: summary
                ),
                summary,
                [
                    "No model-specific KV quantization defaults are known for this model ID.",
                    "Fallback keeps all KV cache tensors in fp16 for safety.",
                    mode.reportDescription,
                ]
            )
        }
    }

    private static func normalizedModelID(_ modelID: String) -> String {
        modelID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}

public enum KVQuantModelFamily: String, Codable, Sendable, Equatable {
    case gemma4 = "gemma_4"
    case gptOSS = "gpt_oss"
    case unknown
}

/// Hardware generation bucket for benchmark candidate selection.
///
/// This is separate from the gate-level `KVQuantCandidateMode`, which describes
/// concrete reference/candidate strings parsed by the benchmark CLI.
public enum KVQuantPolicyCandidateMode: String, Codable, Sendable, Equatable {
    case conservative
    case normal
    case aggressiveCandidate = "aggressive_candidate"

    public var reportDescription: String {
        switch self {
        case .conservative:
            return "M1/M2 or unknown hardware uses conservative KV quant candidates."
        case .normal:
            return "M3/M4 hardware uses the normal KV quant candidate set."
        case .aggressiveCandidate:
            return "M5 hardware may evaluate aggressive KV quant candidates behind benchmark gates."
        }
    }
}

public struct KVQuantPlan: Codable, Sendable, Equatable {
    public let enabled: Bool
    public let layerScope: KVQuantLayerScope
    public let tensorTarget: KVQuantTensorTarget
    public let keyPrecision: KVQuantPrecision
    public let valuePrecision: KVQuantPrecision
    public let valueEncoding: KVQuantValueEncoding?
    public let quantizationStartToken: Int?
    public let sinkAware: KVQuantSinkAwareness
    public let rotatingSlidingPrecision: KVQuantPrecision
    public let mtpPolicy: KVQuantMTPPolicy
    public let reportDescription: String

    enum CodingKeys: String, CodingKey {
        case enabled
        case layerScope = "layer_scope"
        case tensorTarget = "tensor_target"
        case keyPrecision = "key_precision"
        case valuePrecision = "value_precision"
        case valueEncoding = "value_encoding"
        case quantizationStartToken = "quantization_start_token"
        case sinkAware = "sink_aware"
        case rotatingSlidingPrecision = "rotating_sliding_precision"
        case mtpPolicy = "mtp_policy"
        case reportDescription = "report_description"
    }

    public init(
        enabled: Bool,
        layerScope: KVQuantLayerScope,
        tensorTarget: KVQuantTensorTarget,
        keyPrecision: KVQuantPrecision,
        valuePrecision: KVQuantPrecision,
        valueEncoding: KVQuantValueEncoding?,
        quantizationStartToken: Int?,
        sinkAware: KVQuantSinkAwareness,
        rotatingSlidingPrecision: KVQuantPrecision,
        mtpPolicy: KVQuantMTPPolicy,
        reportDescription: String
    ) {
        self.enabled = enabled
        self.layerScope = layerScope
        self.tensorTarget = tensorTarget
        self.keyPrecision = keyPrecision
        self.valuePrecision = valuePrecision
        self.valueEncoding = valueEncoding
        self.quantizationStartToken = quantizationStartToken
        self.sinkAware = sinkAware
        self.rotatingSlidingPrecision = rotatingSlidingPrecision
        self.mtpPolicy = mtpPolicy
        self.reportDescription = reportDescription
    }
}

public enum KVQuantLayerScope: String, Codable, Sendable, Equatable {
    case none
    case fullOnly = "full_only"
    case fullAndGlobalOnly = "full_and_global_only"
}

public enum KVQuantTensorTarget: String, Codable, Sendable, Equatable {
    case none
    case valuesOnly = "values_only"
    case keysAndValues = "keys_and_values"
}

public enum KVQuantPrecision: String, Codable, Sendable, Equatable {
    case fp16
    case quantized4Bit = "quantized_4bit"
    case quantized8Bit = "quantized_8bit"
}

public enum KVQuantValueEncoding: String, Codable, Sendable, Equatable {
    case turbo4Placeholder = "turbo4_placeholder"
    case affine4Placeholder = "affine4_placeholder"
    case affine8 = "affine8"
}

public enum KVQuantSinkAwareness: String, Codable, Sendable, Equatable {
    case notRequired = "not_required"
    case required
}

public enum KVQuantMTPPolicy: String, Codable, Sendable, Equatable {
    case disabled
    case guarded
}
