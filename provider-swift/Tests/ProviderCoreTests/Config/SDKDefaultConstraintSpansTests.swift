import MLXLMCommon
import Testing
@testable import ProviderCore

/// 0.10.13 default flip, scoped to its evidence: `DARKBLOOM_CONSTRAINT_SPANS` is on for the Qwen 3.8
/// 27B build unless the operator sets it (`0` = 0.10.12 everywhere, `1` = every
/// build), off for every other build, and never set process-wide.
@Suite("SDK default: DARKBLOOM_CONSTRAINT_SPANS")
struct SDKDefaultConstraintSpansTests {
    private func on(_ modelId: String, _ modelType: String, _ environment: [String: String] = [:],
                    operatorReading: Bool = false) -> Bool {
        var config = CBv2MTPConfig(enabled: true, freeSpanSpeculation: operatorReading)
        SDKFeatureDefaults.applyMTPDefaults(to: &config, modelId: modelId, modelType: modelType,
            environment: environment)
        return config.freeSpanSpeculation
    }

    @Test func isOnByDefaultForQwen38OnlyAndKillable() {
        #expect(SDKFeatureDefaults.constraintSpansBuilds == ["qwen3.8-27b"])
        #expect(on("EigenLabs/Qwen3.8-27B-4bit-mtp", "qwen3_5"))
        #expect(!on("mlx-community/Qwen3.6-35B-A3B-4bit", "qwen3_5_moe"))
        #expect(!on("mlx-community/Qwen3.5-9B-MLX-4bit", "qwen3_5"))
        #expect(!on("gemma-4-26b-qat-4bit", "gemma4"))
        // `0`: the SDK read it as off and the default leaves it alone.
        #expect(!on("EigenLabs/Qwen3.8-27B-4bit-mtp", "qwen3_5", ["DARKBLOOM_CONSTRAINT_SPANS": "0"]))
        #expect(on("gemma-4-26b-qat-4bit", "gemma4", ["DARKBLOOM_CONSTRAINT_SPANS": "1"], operatorReading: true))
        #expect(!SDKFeatureDefaults.onByDefault.contains("DARKBLOOM_CONSTRAINT_SPANS"))
        #expect(LaunchAgent.passthroughEnvKeys.contains("DARKBLOOM_CONSTRAINT_SPANS"))
        #expect(SDKFeatureDefaults.summary(environment: [:], injected: [])?
            .contains("DARKBLOOM_CONSTRAINT_SPANS (qwen3.8-27b)") == true)
    }
}
