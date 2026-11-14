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

    /// GLM-5.3-Flash's native engine has no constraint spans, so its default
    /// does not wait for them; the operator's `0` still turns it off.
    @Test func isOnByDefaultForTheNativeGLMBuildWithoutSpansAndKillable() {
        let glm = "EigenLabs/GLM-5.3-Flash-MLX-NVFP4-mtp"
        #expect(SDKFeatureDefaults.nativeGrammarMTPBuilds == [glm.lowercased()])
        #expect(!SDKFeatureDefaults.constraintSpansBuilds.contains(glm.lowercased()))
        #expect(on(glm, spans: false) && on(glm))
        #expect(!on(glm, ["DARKBLOOM_CBV2_MTP_GRAMMAR": "0"], spans: false))
        #expect(!on("EigenLabs/GLM-5.3-Flash-MLX-NVFP4", spans: false))
        // A grammar-only Qwen listing still waits for its spans.
        var config = CBv2MTPConfig(enabled: true, constrainedSpeculation: false, freeSpanSpeculation: false)
        SDKFeatureDefaults.applyMTPDefaults(to: &config, modelId: "EigenLabs/Qwen3.8-27B-4bit-mtp",
            environment: [:], processEnvironment: [:], spansBuilds: [])
        #expect(!config.constrainedSpeculation)
        #expect(SDKFeatureDefaults.summary(environment: [:], injected: [])?
            .contains("DARKBLOOM_CBV2_MTP_GRAMMAR (eigenlabs/glm-5.3-flash-mlx-nvfp4-mtp, native, no spans)") == true)
    }
}
