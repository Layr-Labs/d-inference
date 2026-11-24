import MLXLMCommon
import Testing
@testable import ProviderCore

/// The SDK reads `DARKBLOOM_MTP_REPETITION_PENALTY_ROWS` once per process
/// (`CBv2MTPConfig.envRepetitionPenaltySpeculation`): on the builds that opt
/// in, rows with a repetition penalty speculate unless it is `0`. The rollback
/// must reach a background provider too, so the LaunchAgent forwards the
/// operator's value.
@Suite("MTP repetition-penalty-row switch reaches the LaunchAgent")
struct MTPRepetitionPenaltyRowsSwitchTests {
    @Test func rollbackIsForwarded() {
        let key = MTPRepetitionPenaltyRows.environmentKey
        #expect(key == "DARKBLOOM_MTP_REPETITION_PENALTY_ROWS")
        #expect(key != MTPPenaltyRows.environmentKey)
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key))
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "0"])[key] == "0")
        #expect(LaunchAgent.passthroughEnvironment(from: [:])[key] == nil)
    }

    /// The catalog Qwen 3.5/3.6 builds, Gemma 4 26B QAT and Inkling 2 Mini, the
    /// presence/frequency builds, all with target-prefix acceptance. Exact ids:
    /// no other quantization, casing or family.
    @Test func onlyTheCatalogQwenGemmaQATAndInklingBuildsOptIn() {
        for id in [
            "Qwen3.5-9B", "qwen3.5-35b-a3b", "qwen3.6-35b-a3b-vl-mtp-mxfp8", "gemma-4-26b-qat-4bit",
            "thinkingmachines/Inkling-2-Mini",
        ] {
            var config = CBv2MTPConfig(enabled: true)
            let on = SDKFeatureDefaults.applyMTPDefaults(
                to: &config, modelId: id, environment: [:], processEnvironment: [:])
            #expect(config.repetitionPenaltySpeculation, "\(id)")
            #expect(
                config.effectiveRepetitionPenaltySpeculation
                    == CBv2MTPConfig.envRepetitionPenaltySpeculation, "\(id)")
            #expect(
                on.contains(MTPRepetitionPenaltyRows.environmentKey)
                    == CBv2MTPConfig.envRepetitionPenaltySpeculation, "\(id)")
        }
        for id in [
            "gemma-4-26b", "gemma-4-26b-8bit", "GEMMA-4-26B-QAT-4BIT", "EigenLabs/Qwen3.8-27B-4bit-mtp",
            "mlx-community/Qwen3.5-9B-4bit", "qwen3.5-35b-a3b-8bit", "glm-5.3-flash", "nvidia-nemotron-3.5-super",
            "qwen3.5-9b", "QWEN3.6-35B-A3B-VL-MTP-MXFP8", "thinkingmachines/inkling-2-mini", "Inkling-2-Mini",
        ] {
            var config = CBv2MTPConfig(enabled: true)
            let on = SDKFeatureDefaults.applyMTPDefaults(
                to: &config, modelId: id, environment: [:], processEnvironment: [:])
            #expect(!config.repetitionPenaltySpeculation, "\(id)")
            #expect(!on.contains(MTPRepetitionPenaltyRows.environmentKey), "\(id)")
        }
    }

    /// The repetition opt-in is its own switch: the presence/frequency opt-in
    /// does not imply it, and an operator value cannot widen the builds.
    @Test func theOptInIsSeparateAndOnlyTheListCanWidenIt() {
        var config = CBv2MTPConfig(enabled: true, penaltySpeculation: true)
        SDKFeatureDefaults.applyMTPDefaults(
            to: &config, modelId: "gemma-4-26b", environment: [MTPRepetitionPenaltyRows.environmentKey: "1"],
            processEnvironment: [MTPRepetitionPenaltyRows.environmentKey: "1"])
        #expect(!config.repetitionPenaltySpeculation)
        var listed = CBv2MTPConfig(enabled: true)
        SDKFeatureDefaults.applyMTPDefaults(
            to: &listed, modelId: "Qwen3.5-9B", environment: [:], processEnvironment: [:],
            penaltyBuilds: [], repetitionPenaltyBuilds: ["Qwen3.5-9B"])
        #expect(listed.repetitionPenaltySpeculation && !listed.penaltySpeculation)
        #expect(CBv2MTPVerifyPenalties.appliesRepetition(.init(temperature: 0.5, repetitionPenalty: 1.2)))
        #expect(!CBv2MTPVerifyPenalties.appliesRepetition(.init(temperature: 0.5, presencePenalty: 1.5)))
    }

    @Test func startupSummaryNamesTheBuilds() {
        let line = SDKFeatureDefaults.summary(environment: [:], injected: [])
        #expect(
            line?.contains(
                "DARKBLOOM_MTP_REPETITION_PENALTY_ROWS (Qwen3.5-9B, gemma-4-26b-qat-4bit, qwen3.5-35b-a3b, qwen3.6-35b-a3b-vl-mtp-mxfp8, thinkingmachines/Inkling-2-Mini)")
                == CBv2MTPConfig.envRepetitionPenaltySpeculation)
        let none = SDKFeatureDefaults.summary(
            environment: [:], injected: [], spansBuilds: [], grammarBuilds: [], repetitionPenaltyBuilds: [])
        #expect(none?.contains(MTPRepetitionPenaltyRows.environmentKey) != true)
    }
}
