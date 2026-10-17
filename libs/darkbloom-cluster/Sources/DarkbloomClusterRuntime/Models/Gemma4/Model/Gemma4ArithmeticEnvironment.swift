import Foundation

/// The process environment a Gemma stage must run in so that it computes what
/// the serving engine computes. Evaluated before any model is constructed: MLX
/// and the model library read these values once per process.
///
/// The provider projects its Gemma settings into the first two Gemma values at
/// start (`GemmaOptimizationEnvironment`, both defaults on); the others are the
/// values the registered Qwen contract already requires. The prompt controls
/// must be absent because a stage restates their defaults, below.
/// It does not certify a backend, binary, hardware identity or timing.
enum Gemma4ArithmeticEnvironment {
    static let contract = "gemma4_cbv2_query128_bf16_tf32_weighted_r1_v1"
    /// The product's defaults when its three prompt controls are unset
    /// (`Gemma4Text.swift` at the pinned mlx-swift-lm revision). A process that
    /// sets any of them is refused, so these are the values the product itself
    /// would use in this process; `Gemma4StagePromptPolicy` applies them.
    static let finalLayerTailRows = 1
    static let finalLayerTailMinimumChunk = 128
    static let finalLayerLastQuery = true
    static let requiredValues: [String: String] = [
        "DARKBLOOM_CBV2_ATTN_QUERY_BLOCK": "128",
        "DARKBLOOM_BF16_WEIGHTS": "1",
        "MLX_ENABLE_TF32": "1",
        "MLX_GEMMA4_FUSED_WEIGHTED_UNSORT": "1",
        "MLX_GATHER_QMM_EXPERT_SLICES": "trust",
    ]
    static let requiredAbsentNames = [
        "MLX_METAL_GPU_ARCH", "MLX_SDPA_BLOCKS", "MLX_COMPILED_DECODE", "MLX_QUANTIZED_CONSTANT_CACHE",
        "DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL", "DARKBLOOM_GEMMA4_PREFILL_TAIL_ROWS",
        "DARKBLOOM_GEMMA4_PREFILL_TAIL_MIN_CHUNK", "DARKBLOOM_GEMMA4_PREFILL_LAST_QUERY",
    ]

    struct Receipt: Encodable, Equatable {
        let contract: String
        let requiredValues: [String: String]
        let requiredAbsentNames: [String]
        /// The restated prompt defaults this contract binds.
        let finalLayerTailRows: Int
        let finalLayerTailMinimumChunk: Int
        let finalLayerLastQuery: Bool
        let actualProcessEnvironmentMustBePassedBeforeMLXInitialization = true
        let sourceBinaryMetalLibraryAndHardwareIdentityStillRequired = true
        let numericalOrPerformanceQualificationEstablished = false
    }

    static func admit(_ environment: [String: String]) throws -> Receipt {
        for name in requiredValues.keys.sorted() {
            guard environment[name] == requiredValues[name] else {
                throw ProbeError("Gemma stage arithmetic requires exact " + name + "=" + requiredValues[name]!)
            }
        }
        for name in requiredAbsentNames {
            // Present-but-empty is intentionally different from absence.
            guard environment[name] == nil else {
                throw ProbeError("Gemma stage arithmetic requires absent " + name)
            }
        }
        return .init(contract: contract, requiredValues: requiredValues,
            requiredAbsentNames: requiredAbsentNames, finalLayerTailRows: finalLayerTailRows,
            finalLayerTailMinimumChunk: finalLayerTailMinimumChunk, finalLayerLastQuery: finalLayerLastQuery)
    }
}
