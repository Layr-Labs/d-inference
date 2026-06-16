// Copyright © 2026 Eigen Labs.
//
// Engine-level KV-quantization scheme used by the continuous-batching
// scheduler. v1 is intentionally narrow: K8V8 affine, group size 128,
// applied only to Gemma 4 full-attention layers. The scheme mirrors the
// validated benchmark candidate and provides the byte-reduction ratio
// that admission accounting uses.

import Foundation
import MLX
import MLXLMCommon

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
            mode: .affine
        )
    }

    /// Effective K+V bytes per token per `(kvHeads * headDim)` element.
    /// Baseline fp16 K+V = 4.0 bytes/elem.
    public var effectiveKVBytesPerTokenPerElem: Double {
        candidateMode.effectiveKVBytesPerTokenPerElem
    }

    /// Ratio of quantized K+V bytes vs fp16 K+V bytes (≈0.5156 for K8V8 g128).
    public var bytesRatioVsFP16: Double {
        effectiveKVBytesPerTokenPerElem / 4.0
    }

    public init(candidateMode: KVQuantCandidateMode) {
        self.candidateMode = candidateMode
    }

    /// v1 validated Gemma winner: K8V8 affine, group size 128.
    public static let gemma4K8V8G128 = KVQuantEngineScheme(candidateMode: .k8v8g128)
}
