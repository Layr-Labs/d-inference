// Copyright © 2026 Eigen Labs.
//
// Engine-level KV-quantization scheme used by the continuous-batching
// scheduler. v1 is intentionally narrow: K8V8 affine, group size 128 for
// Gemma 4 (kernel path) and group size 64 for GPT-OSS (dequant path).
// The scheme mirrors the validated benchmark candidate and provides the
// byte-reduction ratio that admission accounting uses.

import Foundation
import MLX
import MLXLMCommon

extension KVQuantCandidateMode {
    /// Whether this candidate uses the dequant-only batched cache (stores
    /// quantized, but attends on dequantized fp16) or the native quantized
    /// attention kernel.
    public var cacheKind: KVQuantCacheKind {
        switch self {
        case .k8v8g64Dequant, .k6v6g64Dequant:
            return .dequant
        default:
            return .kernel
        }
    }
}

/// Engine-level KV-quantization scheme. This is separate from the broader
/// ``KVQuantPolicy`` benchmark scaffolding: it describes the *concrete*
/// cache that the scheduler builds when quantization is enabled.
public struct KVQuantEngineScheme: Sendable, Equatable {

    /// The benchmark candidate this engine scheme is derived from.
    /// Used to reuse the existing honest byte-accounting formula
    /// ``KVQuantCandidateMode/effectiveKVBytesPerTokenPerElem``.
    public let candidateMode: KVQuantCandidateMode

    /// Corresponding scheduler configuration consumed by ``MLXLMCommon.Scheduler``.
    public var schedulerConfig: KVQuantizationConfig {
        KVQuantizationConfig(
            groupSize: candidateMode.groupSize ?? 128,
            bits: candidateMode.storedBitsK,
            mode: .affine,
            cacheKind: candidateMode.cacheKind
        )
    }

    /// Effective K+V bytes per token per `(kvHeads * headDim)` element.
    /// Baseline fp16 K+V = 4.0 bytes/elem.
    public var effectiveKVBytesPerTokenPerElem: Double {
        candidateMode.effectiveKVBytesPerTokenPerElem
    }

    /// Ratio of quantized K+V bytes vs fp16 K+V bytes (≈0.5156 for K8V8 g128,
    /// ≈0.5312 for K8V8 g64).
    public var bytesRatioVsFP16: Double {
        effectiveKVBytesPerTokenPerElem / 4.0
    }

    public init(candidateMode: KVQuantCandidateMode) {
        self.candidateMode = candidateMode
    }

    /// v1 validated Gemma winner: K8V8 affine, group size 128, kernel path.
    public static let gemma4K8V8G128 = KVQuantEngineScheme(candidateMode: .k8v8g128)

    /// v1 GPT-OSS winner: K8V8 affine, group size 64, dequant path.
    /// Required because GPT-OSS's quantized attention kernel fatals on sinks;
    /// the cache stores quantized but attends on the dequantized fp16 view.
    public static let gptOSSK8V8G64 = KVQuantEngineScheme(candidateMode: .k8v8g64Dequant)
}

extension BatchScheduler {

    /// Resolve the engine-level KV-quant scheme for a loaded model.
    ///
    /// Returns `nil` when quantization is disabled or the model family is not
    /// yet validated. For GPT-OSS we additionally guard that the configured
    /// group size (64) divides `head_dim` and does not exceed it, so the
    /// invalid g128 case is rejected before the cache is built.
    static func resolveKVQuantScheme(
        modelID: String,
        architecture: ModelArchitecture,
        kvQuantEnabled: Bool
    ) -> KVQuantEngineScheme? {
        guard kvQuantEnabled else { return nil }

        switch KVQuantPolicy.classify(modelID: modelID) {
        case .gemma4:
            return .gemma4K8V8G128
        case .gptOSS:
            guard let headDim = architecture.headDim,
                  headDim >= 64,
                  headDim % 64 == 0
            else {
                return nil
            }
            return .gptOSSK8V8G64
        case .unknown:
            return nil
        }
    }
}
