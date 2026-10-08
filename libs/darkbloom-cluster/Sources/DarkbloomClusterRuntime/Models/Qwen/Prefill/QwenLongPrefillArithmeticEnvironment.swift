import Foundation

/// A deliberately small source-bound arithmetic contract, evaluated before any
/// model construction or MLX static environment cache is initialized. The caller
/// passes the actual process environment; this helper performs no global reads.
/// It does not certify a backend, binary, hardware identity or timing environment.
enum QwenLongPrefillArithmeticEnvironment {
    static let contract = "qwen_cbv2_query128_bf16_tf32_default_v1"
    static let requiredValues: [String: String] = [
        "DARKBLOOM_CBV2_ATTN_QUERY_BLOCK": "128",
        "DARKBLOOM_BF16_WEIGHTS": "1",
        "MLX_ENABLE_TF32": "1",
    ]
    static let requiredAbsentNames = ["MLX_METAL_GPU_ARCH", "MLX_SDPA_BLOCKS"]

    struct Receipt: Encodable, Equatable {
        let contract: String
        let requiredValues: [String: String]
        let requiredAbsentNames: [String]
        let full512TokenChunkQueryBlocks: Int
        let defaultBindings: [String: String]
        let actualProcessEnvironmentMustBePassedBeforeMLXInitialization = true
        let sourceBinaryMetalLibraryAndHardwareIdentityStillRequired = true
        let sameChunkFullModelReferenceStillRequired = true
        let doesNotValidateOtherTimingOrResourceEnvironment = true
        let numericalOrPerformanceQualificationEstablished = false
    }

    static func admit(_ environment: [String: String]) throws -> Receipt {
        for name in requiredValues.keys.sorted() {
            guard environment[name] == requiredValues[name] else {
                throw QwenLongPrefillBudgetError.invalid("Long-prefill arithmetic requires exact " + name + "=" + requiredValues[name]!)
            }
        }
        for name in requiredAbsentNames {
            // Present-but-empty is intentionally different from absence.
            guard environment[name] == nil else {
                throw QwenLongPrefillBudgetError.invalid("Long-prefill arithmetic requires absent " + name)
            }
        }
        return .init(contract: contract, requiredValues: requiredValues,
            requiredAbsentNames: requiredAbsentNames, full512TokenChunkQueryBlocks: 4,
            defaultBindings: [
                "MLX_METAL_GPU_ARCH": "detect actual Metal device architecture; no override",
                "MLX_SDPA_BLOCKS": "source default 0; native adaptive block selection",
                "MLX_ENABLE_TF32": "explicit 1 matches pinned source default; permits eligible NAX paths",
                "DARKBLOOM_BF16_WEIGHTS": "explicit 1 converts stored Float16 tensors to BFloat16 before subsequent arithmetic",
                "DARKBLOOM_CBV2_ATTN_QUERY_BLOCK": "explicit 128 matches pinned source default; chunk512 uses four query blocks",
            ])
    }
}
