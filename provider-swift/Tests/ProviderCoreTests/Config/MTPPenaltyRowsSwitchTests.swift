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

    @Test func offByDefault() {
        for id in ["Qwen3.5-9B", "qwen3.5-35b-a3b", "qwen3.6-35b-a3b-vl-mtp-mxfp8"] {
            for value in [nil, "", "0", "off", "2"] as [String?] {
                var config = CBv2MTPConfig(enabled: true)
                let env = value.map { [MTPPenaltyRows.environmentKey: $0] } ?? [:]
                SDKFeatureDefaults.applyMTPDefaults(
                    to: &config, modelId: id, environment: env, processEnvironment: [:])
                #expect(!config.penaltySpeculation, "\(id) \(String(describing: value))")
            }
        }
    }

    @Test func onlyTheCatalogQwenBuildsOptIn() {
        let on1 = [MTPPenaltyRows.environmentKey: "1"]
        for id in ["Qwen3.5-9B", "qwen3.5-35b-a3b", "qwen3.6-35b-a3b-vl-mtp-mxfp8"] {
            var config = CBv2MTPConfig(enabled: true)
            let on = SDKFeatureDefaults.applyMTPDefaults(
                to: &config, modelId: id, environment: on1, processEnvironment: [:])
            #expect(config.penaltySpeculation, "\(id)")
            #expect(on.contains(MTPPenaltyRows.environmentKey) == CBv2MTPConfig.envPenaltySpeculation)
        }
        for id in [
            "gemma-4-26b-qat-4bit", "EigenLabs/Qwen3.8-27B-4bit-mtp", "mlx-community/Qwen3.5-9B-4bit",
            "qwen3.5-35b-a3b-8bit", "glm-5.3-flash", "nvidia-nemotron-3.5-super",
            "qwen3.5-9b", "QWEN3.6-35B-A3B-VL-MTP-MXFP8",
        ] {
            var config = CBv2MTPConfig(enabled: true)
            SDKFeatureDefaults.applyMTPDefaults(
                to: &config, modelId: id, environment: on1, processEnvironment: [:])
            #expect(!config.penaltySpeculation, "\(id)")
        }
    }

    @Test func startupSummaryNamesTheBuilds() {
        let names = "DARKBLOOM_MTP_PENALTY_ROWS (Qwen3.5-9B, qwen3.5-35b-a3b, qwen3.6-35b-a3b-vl-mtp-mxfp8)"
        #expect(SDKFeatureDefaults.summary(environment: [:], injected: [])?.contains(names) != true)
        #expect(
            SDKFeatureDefaults.summary(
                environment: [MTPPenaltyRows.environmentKey: "1"], injected: [])?.contains(names) == true)
    }
}
