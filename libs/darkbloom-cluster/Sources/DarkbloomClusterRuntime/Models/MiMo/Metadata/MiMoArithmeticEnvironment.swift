import Foundation

/// The arithmetic contract both MiMo ranks must start under, evaluated on the
/// actual process environment before any model construction. MiMo's text class
/// selects its short-forward kernels, attention path and expert reduction from
/// `DARKBLOOM_MIMO_*` switches that default to the product's behaviour; this
/// contract is "every such switch absent", so both ranks run the product's
/// defaults and neither can be moved off them by its launcher. It does not
/// certify a backend, binary, chip or timing environment: the two ranks of a
/// mixed pair may still select different kernels for their own layers.
enum MiMoArithmeticEnvironment {
    static let contract = "mimo_v26_text_ordinary_cache_bf16_defaults_v1"
    static let requiredValues: [String: String] = ["MLX_ENABLE_TF32": "1"]
    static let requiredAbsentNames = ["MLX_METAL_GPU_ARCH", "MLX_SDPA_BLOCKS"]
    static let requiredAbsentPrefix = "DARKBLOOM_MIMO_"

    struct Receipt: Encodable, Equatable {
        let contract: String
        let requiredValues: [String: String]
        let requiredAbsentNames: [String]
        let requiredAbsentPrefix: String
        let cache = "ordinary KVCacheSimple and RotatingKVCache; not the engine's paged pool"
        let numericalOrPerformanceQualificationEstablished = false
    }

    static func admit(_ environment: [String: String]) throws -> Receipt {
        for name in requiredValues.keys.sorted() {
            guard environment[name] == requiredValues[name] else {
                throw MiMoProfileError("MiMo arithmetic requires exact " + name + "=" + requiredValues[name]!)
            }
        }
        for name in requiredAbsentNames {
            guard environment[name] == nil else { throw MiMoProfileError("MiMo arithmetic requires absent " + name) }
        }
        if let name = environment.keys.sorted().first(where: { $0.hasPrefix(requiredAbsentPrefix) }) {
            throw MiMoProfileError("MiMo arithmetic requires the product defaults; \(name) overrides one")
        }
        return .init(contract: contract, requiredValues: requiredValues,
                     requiredAbsentNames: requiredAbsentNames, requiredAbsentPrefix: requiredAbsentPrefix)
    }
}
