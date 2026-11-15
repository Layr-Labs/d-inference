import MLXLMCommon
import Testing
@testable import ProviderCore

/// 0.10.13 default flip, scoped to its evidence: `DARKBLOOM_CONSTRAINT_SPANS` is on
/// for the measured build (`EigenLabs/Qwen3.8-27B-4bit-mtp`) unless the operator
/// sets it (`0` = 0.10.12 everywhere, `1` = every eligible build), off for every
/// other build, and never set process-wide.
@Suite("SDK default: DARKBLOOM_CONSTRAINT_SPANS")
struct SDKDefaultConstraintSpansTests {
    private func on(_ modelId: String, _ environment: [String: String] = [:],
                    operatorReading: Bool = false) -> Bool {
        var config = CBv2MTPConfig(enabled: true, freeSpanSpeculation: operatorReading)
        SDKFeatureDefaults.applyMTPDefaults(to: &config, modelId: modelId, environment: environment,
            processEnvironment: [:])
        return config.freeSpanSpeculation
    }

    @Test func isOnByDefaultForTheMeasuredBuildOnlyAndKillable() {
        #expect(SDKFeatureDefaults.constraintSpansBuilds == ["eigenlabs/qwen3.8-27b-4bit-mtp"])
        #expect(on("EigenLabs/Qwen3.8-27B-4bit-mtp"))
        for id in ["mlx-community/Qwen3.8-27B-8bit-mtp", "EigenLabs/Qwen3.8-27B-4bit",
                   "mlx-community/Qwen3.6-35B-A3B-4bit", "gemma-4-26b-qat-4bit"] {
            #expect(!on(id), "\(id)")
        }
        // `0`: the SDK read it as off and the default leaves it alone.
        #expect(!on("EigenLabs/Qwen3.8-27B-4bit-mtp", ["DARKBLOOM_CONSTRAINT_SPANS": "0"]))
        #expect(on("gemma-4-26b-qat-4bit", ["DARKBLOOM_CONSTRAINT_SPANS": "1"], operatorReading: true))
        #expect(!SDKFeatureDefaults.onByDefault.contains("DARKBLOOM_CONSTRAINT_SPANS"))
        #expect(LaunchAgent.passthroughEnvKeys.contains("DARKBLOOM_CONSTRAINT_SPANS"))
        #expect(SDKFeatureDefaults.summary(environment: [:], injected: [])?
            .contains("DARKBLOOM_CONSTRAINT_SPANS (eigenlabs/qwen3.8-27b-4bit-mtp)") == true)
    }
}
