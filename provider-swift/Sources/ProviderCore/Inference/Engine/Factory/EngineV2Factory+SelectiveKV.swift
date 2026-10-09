import Foundation
import MLXLLM
import MLXLMCommon
import MLXVLM

extension EngineV2Factory {
    static let selectiveKVEnvKey = "DARKBLOOM_CBV2_SELECTIVE_KV"
    /// Fixed before model evaluation; larger headers are outside this cohort.
    @_spi(Benchmarking)
    public static let instructionProtectedPrefixTokens = 128

    /// Lossy retention needs exact-artifact quality evidence before serving.
    /// Deliberately require explicit contiguous selection for like-for-like
    /// native controls. MiMo and unqualified model families never enter here.
    static func selectiveKVPolicy(
        model: any LanguageModel, purpose: ConstructionPurpose,
        backend: EngineV2KVBackendSelection, environment: [String: String]
    ) throws -> CBv2SelectiveKVPolicy? {
        guard let raw = environment[selectiveKVEnvKey], !raw.isEmpty, raw != "0" else { return nil }
        guard ["half", "instruction-half"].contains(raw), purpose == .benchmark, backend == .contiguous,
              model is GPTOSSModel || model is Gemma4Model || model is Gemma4TextModel
                || model is MLXVLM.Gemma4
        else {
            throw CBv2KVError.backendIneligible(reason:
                "\(selectiveKVEnvKey)=\(raw) requires an explicit contiguous Gemma 4 or GPT-OSS benchmark")
        }
        guard raw != "instruction-half" || model is GPTOSSModel else {
            throw CBv2KVError.backendIneligible(reason:
                "instruction-half is a separately qualified GPT-OSS benchmark candidate")
        }
        return .init(protectedPrefixTokens:
            raw == "instruction-half" ? instructionProtectedPrefixTokens : 0)
    }
}
