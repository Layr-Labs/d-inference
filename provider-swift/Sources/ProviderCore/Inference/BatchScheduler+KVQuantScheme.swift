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

    /// v1 GPT-OSS scheme: K8V8 affine, group size 64, dequant path.
    ///
    /// Measured decision (concurrency sweep, decode-window metric): under
    /// concurrency the dequant path decodes at near-parity with fp16
    /// (~0.93–1.00x) because it keeps MLX's fused flash attention and the per-step
    /// dequant is well overlapped. The native quantized kernel (`.k8v8g64`, which
    /// is now sink-correct) is *slower* at decode (~0.6–0.94x) because MLX has no
    /// fused quantized attention kernel — the hand-rolled `quantizedMM`+softmax
    /// path can't match fused flash. Both store identical bytes (~1.88x capacity),
    /// so dequant is the better choice for GPT-OSS. Set
    /// `DARKBLOOM_KV_GPTOSS_KERNEL=1` to force the kernel path for A/B testing.
    public static let gptOSSK8V8G64 = KVQuantEngineScheme(candidateMode: .k8v8g64Dequant)
}

extension BatchScheduler {

    /// Resolve the engine-level KV-quant scheme for a loaded model.
    ///
    /// Returns `nil` when quantization is disabled or the model family is not
    /// yet validated. For both families we guard that the scheme's group size
    /// divides the quantized layer's `head_dim` and does not exceed it, so an
    /// invalid (group size > head_dim, or non-divisible) case is rejected here —
    /// before the cache is built — instead of trapping the quantized cache's
    /// `head_dim % groupSize == 0` precondition at first decode.
    static func resolveKVQuantScheme(
        modelID: String,
        architecture: ModelArchitecture,
        kvQuantEnabled: Bool
    ) -> KVQuantEngineScheme? {
        guard kvQuantEnabled else { return nil }

        switch KVQuantPolicy.classify(modelID: modelID) {
        case .gemma4:
            // Gemma 4 quantizes the full/global attention layers at group size
            // 128. Those layers use `global_head_dim` when the model declares one,
            // otherwise `head_dim`. Guard the actual quantized-layer dim so a
            // malformed/variant config disables KV quant rather than crashing.
            let gemmaHeadDim = architecture.globalHeadDim ?? architecture.headDim
            guard let headDim = gemmaHeadDim,
                  headDim >= 128,
                  headDim % 128 == 0
            else {
                return nil
            }
            return .gemma4K8V8G128
        case .gptOSS:
            guard let headDim = architecture.headDim,
                  headDim >= 64,
                  headDim % 64 == 0
            else {
                return nil
            }
            // Experiment hook: force the native quantized kernel path
            // for A/B perf comparison. Default is dequant, which decodes at
            // near-parity with fp16 under concurrency (the kernel path is slower
            // because MLX lacks a fused quantized attention kernel).
            if ProcessInfo.processInfo.environment["DARKBLOOM_KV_GPTOSS_KERNEL"] == "1" {
                return KVQuantEngineScheme(candidateMode: .k8v8g64)
            }
            return .gptOSSK8V8G64
        case .unknown:
            return nil
        }
    }
}
