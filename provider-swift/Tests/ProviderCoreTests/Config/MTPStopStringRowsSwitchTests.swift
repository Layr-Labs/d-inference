import MLXLMCommon
import Testing
@testable import ProviderCore

/// The SDK reads `DARKBLOOM_MTP_STOP_STRING_ROWS` once per process
/// (`CBv2MTPConfig.envStopStringSpeculation`): on the builds that opt in, rows
/// with `stop` strings speculate unless it is `0`. The rollback must reach a
/// background provider too, so the LaunchAgent forwards the operator's value.
@Suite("MTP stop-string-row switch reaches the LaunchAgent")
struct MTPStopStringRowsSwitchTests {
    @Test func rollbackIsForwarded() {
        let key = MTPStopStringRows.environmentKey
        #expect(key == "DARKBLOOM_MTP_STOP_STRING_ROWS")
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key))
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "0"])[key] == "0")
        #expect(LaunchAgent.passthroughEnvironment(from: [:])[key] == nil)
    }

    @Test func onlyTheCatalogGemmaQATAndInklingBuildsOptIn() {
        for id in ["gemma-4-26b-qat-4bit", "thinkingmachines/Inkling-2-Mini"] {
            var config = CBv2MTPConfig(enabled: true)
            let on = SDKFeatureDefaults.applyMTPDefaults(
                to: &config, modelId: id, environment: [:], processEnvironment: [:])
            #expect(config.stopStringSpeculation, "\(id)")
            #expect(on.contains(MTPStopStringRows.environmentKey) == CBv2MTPConfig.envStopStringSpeculation)
        }
        for id in [
            "gemma-4-26b", "gemma-4-26b-8bit", "GEMMA-4-26B-QAT-4BIT", "Qwen3.5-9B", "qwen3.5-35b-a3b",
            "qwen3.6-35b-a3b-vl-mtp-mxfp8", "EigenLabs/Qwen3.8-27B-4bit-mtp", "glm-5.3-flash",
            "nvidia-nemotron-3.5-super", "thinkingmachines/inkling-2-mini", "Inkling-2-Mini",
        ] {
            var config = CBv2MTPConfig(enabled: true)
            SDKFeatureDefaults.applyMTPDefaults(
                to: &config, modelId: id, environment: [:], processEnvironment: [:])
            #expect(!config.stopStringSpeculation, "\(id)")
        }
    }

    @Test func startupSummaryNamesTheBuild() {
        let line = SDKFeatureDefaults.summary(environment: [:], injected: [])
        #expect(
            line?.contains("DARKBLOOM_MTP_STOP_STRING_ROWS (gemma-4-26b-qat-4bit, thinkingmachines/Inkling-2-Mini)")
                == CBv2MTPConfig.envStopStringSpeculation)
    }
}
