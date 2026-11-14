import MLXLMCommon
import Testing
@testable import ProviderCore

/// 0.10.13 default flip, scoped to its evidence: `DARKBLOOM_CBV2_MTP_GRAMMAR` is on for the Qwen 3.8
/// 27B build unless the operator sets it (`0` = 0.10.12 everywhere, `1` = every
/// build), off for every other build, and never set process-wide.
@Suite("SDK default: DARKBLOOM_CBV2_MTP_GRAMMAR")
struct SDKDefaultGrammarMTPTests {
    private func on(_ modelId: String, _ modelType: String, _ environment: [String: String] = [:],
                    operatorReading: Bool = false) -> Bool {
        var config = CBv2MTPConfig(enabled: true, constrainedSpeculation: operatorReading)
        SDKFeatureDefaults.applyMTPDefaults(to: &config, modelId: modelId, modelType: modelType,
            environment: environment)
        return config.constrainedSpeculation
    }

    @Test func isOnByDefaultForQwen38OnlyAndKillable() {
        #expect(SDKFeatureDefaults.grammarMTPBuilds == ["qwen3.8-27b"])
        #expect(on("EigenLabs/Qwen3.8-27B-4bit-mtp", "qwen3_5"))
        #expect(!on("mlx-community/Qwen3.6-35B-A3B-4bit", "qwen3_5_moe"))
        #expect(!on("mlx-community/Qwen3.5-9B-MLX-4bit", "qwen3_5"))
        #expect(!on("gemma-4-26b-qat-4bit", "gemma4"))
        // `0`: the SDK read it as off and the default leaves it alone.
        #expect(!on("EigenLabs/Qwen3.8-27B-4bit-mtp", "qwen3_5", ["DARKBLOOM_CBV2_MTP_GRAMMAR": "0"]))
        #expect(on("gemma-4-26b-qat-4bit", "gemma4", ["DARKBLOOM_CBV2_MTP_GRAMMAR": "1"], operatorReading: true))
        #expect(!SDKFeatureDefaults.onByDefault.contains("DARKBLOOM_CBV2_MTP_GRAMMAR"))
        #expect(LaunchAgent.passthroughEnvKeys.contains("DARKBLOOM_CBV2_MTP_GRAMMAR"))
        #expect(SDKFeatureDefaults.summary(environment: [:], injected: [])?
            .contains("DARKBLOOM_CBV2_MTP_GRAMMAR (qwen3.8-27b)") == true)
    }
}
