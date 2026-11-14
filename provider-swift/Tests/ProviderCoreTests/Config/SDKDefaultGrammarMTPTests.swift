import MLXLMCommon
import Testing
@testable import ProviderCore

/// 0.10.13 default flip, scoped to its evidence: `DARKBLOOM_CBV2_MTP_GRAMMAR` is on
/// for the measured build (`EigenLabs/Qwen3.8-27B-4bit-mtp`) where constraint spans
/// are on (measured together) unless the operator sets it (`0` = 0.10.12
/// everywhere, `1` = every MTP engine), off for every other build, and never set
/// process-wide.
@Suite("SDK default: DARKBLOOM_CBV2_MTP_GRAMMAR")
struct SDKDefaultGrammarMTPTests {
    /// `spans`: constraint spans are on for this engine (the operator's `1` here).
    private func on(_ modelId: String, _ environment: [String: String] = [:], spans: Bool = true,
                    operatorReading: Bool = false) -> Bool {
        var config = CBv2MTPConfig(enabled: true, constrainedSpeculation: operatorReading,
            freeSpanSpeculation: spans)
        var environment = environment
        if spans, environment["DARKBLOOM_CONSTRAINT_SPANS"] == nil { environment["DARKBLOOM_CONSTRAINT_SPANS"] = "1" }
        SDKFeatureDefaults.applyMTPDefaults(to: &config, modelId: modelId, environment: environment,
            processEnvironment: [:])
        return config.constrainedSpeculation
    }

    @Test func isOnByDefaultForTheMeasuredBuildWithSpansOnlyAndKillable() {
        #expect(SDKFeatureDefaults.grammarMTPBuilds == ["eigenlabs/qwen3.8-27b-4bit-mtp"])
        #expect(on("EigenLabs/Qwen3.8-27B-4bit-mtp"))
        #expect(!on("EigenLabs/Qwen3.8-27B-4bit-mtp", ["DARKBLOOM_CONSTRAINT_SPANS": "0"], spans: false))
        for id in ["mlx-community/Qwen3.8-27B-8bit-mtp", "EigenLabs/Qwen3.8-27B-4bit",
                   "mlx-community/Qwen3.6-35B-A3B-4bit", "gemma-4-26b-qat-4bit"] {
            #expect(!on(id), "\(id)")
        }
        // `0`: the SDK read it as off and the default leaves it alone.
        #expect(!on("EigenLabs/Qwen3.8-27B-4bit-mtp", ["DARKBLOOM_CBV2_MTP_GRAMMAR": "0"]))
        #expect(on("gemma-4-26b-qat-4bit", ["DARKBLOOM_CBV2_MTP_GRAMMAR": "1"], operatorReading: true))
        #expect(!SDKFeatureDefaults.onByDefault.contains("DARKBLOOM_CBV2_MTP_GRAMMAR"))
        #expect(LaunchAgent.passthroughEnvKeys.contains("DARKBLOOM_CBV2_MTP_GRAMMAR"))
        #expect(SDKFeatureDefaults.summary(environment: [:], injected: [])?
            .contains("DARKBLOOM_CBV2_MTP_GRAMMAR (eigenlabs/qwen3.8-27b-4bit-mtp, where constraint spans are on)") == true)
    }
}
