import Foundation

/// The arithmetic contract both GPT-OSS ranks must start under, evaluated on
/// the actual process environment before any model construction.
///
/// A stage holds the experts exactly as the artifact stores them: separate
/// gate and up projections. The stage loader never runs the product class's
/// checkpoint sanitizer, so the product's load-time gate/up fusion
/// (`DARKBLOOM_GPTOSS_FUSED_GATE_UP`) cannot change a stage; the contract still
/// requires every `DARKBLOOM_GPTOSS_*` switch to be absent, so neither rank can
/// be moved onto the compiled expert path or another prompt-output policy by
/// its launcher. It does not certify a backend, binary, chip or timing
/// environment.
enum GPTOSSArithmeticEnvironment {
    static let contract = "gpt_oss_ordinary_cache_split_experts_bf16_defaults_v1"
    static let requiredValues: [String: String] = ["MLX_ENABLE_TF32": "1"]
    static let requiredAbsentNames = ["MLX_METAL_GPU_ARCH", "MLX_SDPA_BLOCKS", "MLX_COMPILED_DECODE"]
    static let requiredAbsentPrefix = "DARKBLOOM_GPTOSS_"

    struct Receipt: Encodable, Equatable {
        let contract: String
        let requiredValues: [String: String]
        let requiredAbsentNames: [String]
        let requiredAbsentPrefix: String
        let expertLayout = "split gate_proj and up_proj as stored; no load-time fusion"
        let cache = "the text class's ordinary growing and rotating attention caches; not the engine's paged pool"
        let numericalOrPerformanceQualificationEstablished = false
    }

    static func admit(_ environment: [String: String]) throws -> Receipt {
        for name in requiredValues.keys.sorted() {
            guard environment[name] == requiredValues[name] else {
                throw GPTOSSProfileError("GPT-OSS arithmetic requires exact " + name + "=" + requiredValues[name]!)
            }
        }
        for name in requiredAbsentNames {
            // Present-but-empty is intentionally different from absence.
            guard environment[name] == nil else { throw GPTOSSProfileError("GPT-OSS arithmetic requires absent " + name) }
        }
        if let name = environment.keys.sorted().first(where: { $0.hasPrefix(requiredAbsentPrefix) }) {
            throw GPTOSSProfileError("GPT-OSS arithmetic requires the stored expert layout and product defaults; \(name) overrides one")
        }
        return .init(contract: contract, requiredValues: requiredValues,
                     requiredAbsentNames: requiredAbsentNames, requiredAbsentPrefix: requiredAbsentPrefix)
    }
}
