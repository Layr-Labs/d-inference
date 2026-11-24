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

    @Test func onlyTheCatalogQwenGemmaQATAndInklingBuildsOptIn() {
        for id in [
            "Qwen3.5-9B", "qwen3.5-35b-a3b", "qwen3.6-35b-a3b-vl-mtp-mxfp8", "gemma-4-26b-qat-4bit",
            "thinkingmachines/Inkling-2-Mini",
        ] {
            var config = CBv2MTPConfig(enabled: true)
            let on = SDKFeatureDefaults.applyMTPDefaults(
                to: &config, modelId: id, environment: [:], processEnvironment: [:])
            #expect(config.penaltySpeculation, "\(id)")
            #expect(on.contains(MTPPenaltyRows.environmentKey) == CBv2MTPConfig.envPenaltySpeculation)
        }
        for id in [
            "gemma-4-26b", "gemma-4-26b-8bit", "EigenLabs/Qwen3.8-27B-4bit-mtp", "mlx-community/Qwen3.5-9B-4bit",
            "qwen3.5-35b-a3b-8bit", "glm-5.3-flash", "nvidia-nemotron-3.5-super",
            "qwen3.5-9b", "QWEN3.6-35B-A3B-VL-MTP-MXFP8", "thinkingmachines/inkling-2-mini", "Inkling-2-Mini",
        ] {
            var config = CBv2MTPConfig(enabled: true)
            SDKFeatureDefaults.applyMTPDefaults(
                to: &config, modelId: id, environment: [:], processEnvironment: [:])
            #expect(!config.penaltySpeculation, "\(id)")
        }
    }

    /// Inkling's penalty rows draft through the SDK's generic penalty-aware
    /// verification. A repetition penalty is not a presence/frequency penalty:
    /// its rows follow their own opt-in (`MTPRepetitionPenaltyRowsSwitchTests`).
    @Test func inklingPenaltyRowsDraftThroughTheGenericVerifier() {
        var config = CBv2MTPConfig(enabled: true)
        SDKFeatureDefaults.applyMTPDefaults(
            to: &config, modelId: "thinkingmachines/Inkling-2-Mini", environment: [:], processEnvironment: [:])
        #expect(config.penaltySpeculation)
        #expect(config.effectivePenaltySpeculation == CBv2MTPConfig.envPenaltySpeculation)
        #expect(CBv2MTPVerifyPenalties.applies(.init(temperature: 0.5, presencePenalty: 0.5)))
        #expect(CBv2MTPVerifyPenalties.applies(.init(temperature: 0, frequencyPenalty: 0.3)))
        #expect(!CBv2MTPVerifyPenalties.applies(.init(temperature: 0.5, repetitionPenalty: 1.2)))
    }

    @Test func startupSummaryNamesTheBuilds() {
        let line = SDKFeatureDefaults.summary(environment: [:], injected: [])
        #expect(
            line?.contains(
                "DARKBLOOM_MTP_PENALTY_ROWS (Qwen3.5-9B, gemma-4-26b-qat-4bit, qwen3.5-35b-a3b, qwen3.6-35b-a3b-vl-mtp-mxfp8, thinkingmachines/Inkling-2-Mini)")
                == CBv2MTPConfig.envPenaltySpeculation)
    }
}
