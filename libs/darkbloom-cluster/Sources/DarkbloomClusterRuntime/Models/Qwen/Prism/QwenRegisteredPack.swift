import Foundation

/// How a registered artifact stores the tensors its layers compute with, and
/// what follows from that for a stage. A closed property of the model's row:
/// nothing here is read from a file or chosen by a caller, and every value is
/// one the loader then holds the artifact and the loaded stage to.
enum QwenRegisteredPack: Equatable {
    /// Affine modules whose scales, biases and plain tensors the stream meets
    /// in BF16 (stored BF16, or stored F16 and converted on load).
    case affineBFloat16
    /// Prism's folded 2-bit pack: every packed module has a signed block
    /// Hadamard transform in front of it, its scales and biases stay F16, and
    /// the norms, the convolution and the two small gated-delta projections
    /// are plain F32. The first norm promotes the stream to F32.
    case prismHadamard

    /// The `model_type` at the root of the artifact's configuration.
    var rootModelType: String {
        switch self {
        case .affineBFloat16: "qwen3_5"
        case .prismHadamard: QwenPrismStageConfiguration.rootModelType
        }
    }

    /// Whether stored F16 tensors are converted to BF16 as they are loaded.
    /// The SDK's loader skips that conversion for a Prism pack; so does this one.
    var convertsFloat16ToBFloat16: Bool { self == .affineBFloat16 }

    /// The one dtype of the residual at a cut, of the attention keys and
    /// values, of the convolution state and of the logits. For the Prism pack
    /// it is not the dtype of the embedding's scales (F16): the loader takes
    /// it from the SDK's own description of the stored layout and refuses a
    /// stage that says anything else, and every frame is checked against it.
    var activationDType: String {
        switch self {
        case .affineBFloat16: "bfloat16"
        case .prismHadamard: "float32"
        }
    }

    var activationElementBytes: Int { self == .prismHadamard ? 4 : 2 }

    /// Whether the pinned decoder replaces a gated-delta layer's four input
    /// projections by one fused bank on its first forward. It does so only
    /// when all four are plain affine modules of one policy; in the Prism
    /// pack two of them are not packed at all, and it declines.
    var fusesGatedDeltaInputProjections: Bool { self == .affineBFloat16 }

    /// Stored tensors of one gated-delta layer's four input projections.
    var gatedDeltaInputProjectionTensors: Int { self == .prismHadamard ? 8 : 12 }
}

extension QwenRegisteredDenseModel {
    var pack: QwenRegisteredPack {
        switch self {
        case .ternaryBonsai2TwentySevenB: .prismHadamard
        default: .affineBFloat16
        }
    }
}

/// What a Prism Hadamard pack's forward depends on in the process environment
/// beyond the dense contract. The pinned SDK latches each switch once, before
/// the first forward, and treats an absent switch as on; the contract requires
/// the explicit value, so two ranks cannot differ by one of them being unset.
enum QwenPrismArithmeticContract {
    static let contract = "qwen_cbv2_query128_tf32_prism_hadamard_f32_v1"
    /// A producer stage's long prefill chunks submit each gated-delta layer's
    /// convolution carry for evaluation ahead of the chunk's own.
    static let prefillCarryName = "DARKBLOOM_BONSAI_PREFILL_CARRY_ASYNC"
    /// A packed module keeps one F32 copy of its F16 scales and biases
    /// instead of widening them on every call.
    static let constantCacheName = "DARKBLOOM_BONSAI_F16_CONSTANT_CACHE"
    /// The process-wide switch that would turn every such copy off.
    static let quantizedConstantCacheName = "MLX_QUANTIZED_CONSTANT_CACHE"

    static let values = [prefillCarryName: "1", constantCacheName: "1"]
    static let absentNames = [quantizedConstantCacheName]
    static let bindings = [
        prefillCarryName: "explicit 1 matches the pinned source default; eligible packed prefill chunks of 128 or more tokens that enter through the packed embedding submit their convolution carry early. A stage that enters through a residual is never eligible",
        constantCacheName: "explicit 1 matches the pinned source default; a packed module whose input is Float32 keeps one Float32 copy of its Float16 scales and biases and reuses it on every call",
        quantizedConstantCacheName: "source default on; required absent so the reuse above cannot be turned off process-wide",
        "DARKBLOOM_BF16_WEIGHTS (Prism Hadamard pack)": "the pack's stored Float16 scales and biases stay Float16: the pinned loader skips the BFloat16 conversion for a packed Hadamard model whatever this variable says, and so does this runtime's",
    ]
}
