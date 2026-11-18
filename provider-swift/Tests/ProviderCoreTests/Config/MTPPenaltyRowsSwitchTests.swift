import MLXLMCommon
import Testing
@testable import ProviderCore

/// The SDK reads `DARKBLOOM_MTP_PENALTY_ROWS` once per process
/// (`CBv2MTPConfig.envPenaltySpeculation`): rows with a presence or frequency
/// penalty speculate unless it is `0`. The rollback must reach a background
/// provider too, so the LaunchAgent forwards the operator's value.
@Suite("MTP penalty-row switch reaches the LaunchAgent")
struct MTPPenaltyRowsSwitchTests {
    @Test func rollbackIsForwarded() {
        let key = MTPPenaltyRows.environmentKey
        #expect(key == "DARKBLOOM_MTP_PENALTY_ROWS")
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key))
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "0"])[key] == "0")
        #expect(LaunchAgent.passthroughEnvironment(from: [:])[key] == nil)
    }

    @Test func onlyTheCatalogQwenBuildsOptIn() {
        for id in ["Qwen3.5-9B", "qwen3.5-35b-a3b", "qwen3.6-35b-a3b-vl-mtp-mxfp8"] {
            var config = CBv2MTPConfig(enabled: true)
            let on = SDKFeatureDefaults.applyMTPDefaults(
                to: &config, modelId: id, environment: [:], processEnvironment: [:])
            #expect(config.penaltySpeculation, "\(id)")
            #expect(on.contains(MTPPenaltyRows.environmentKey) == CBv2MTPConfig.envPenaltySpeculation)
        }
        for id in [
            "gemma-4-26b-qat-4bit", "EigenLabs/Qwen3.8-27B-4bit-mtp", "mlx-community/Qwen3.5-9B-4bit",
            "qwen3.5-35b-a3b-8bit", "glm-5.3-flash", "nvidia-nemotron-3.5-super",
        ] {
            var config = CBv2MTPConfig(enabled: true)
            SDKFeatureDefaults.applyMTPDefaults(
                to: &config, modelId: id, environment: [:], processEnvironment: [:])
            #expect(!config.penaltySpeculation, "\(id)")
        }
    }
}
