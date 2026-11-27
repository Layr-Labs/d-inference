import MLXLLM
import MLXLMCommon
import ProviderCoreFoundation
import Testing
@testable import ProviderCore

/// The SDK reads `DARKBLOOM_MTP_LOGIT_BIAS_ROWS` once per process
/// (`CBv2MTPConfig.envLogitBiasSpeculation`): on the builds that opt in, rows
/// with a `logit_bias` speculate unless it is `0`. The rollback must reach a
/// background provider too, so the LaunchAgent forwards the operator's value,
/// and the batch-depth rollback beside it.
@Suite("MTP logit-bias-row switch reaches the LaunchAgent")
struct MTPLogitBiasRowsSwitchTests {
    @Test func rollbacksAreForwarded() {
        for key in [MTPLogitBiasRows.environmentKey, "DARKBLOOM_CBV2_MTP_BATCH_DEPTH"] {
            #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key))
            #expect(LaunchAgent.passthroughEnvironment(from: [key: "0"])[key] == "0")
            #expect(LaunchAgent.passthroughEnvironment(from: [:])[key] == nil)
        }
        #expect(MTPLogitBiasRows.environmentKey == "DARKBLOOM_MTP_LOGIT_BIAS_ROWS")
    }

    @Test func onlyInklingOptsIn() {
        for id in Inkling2ModelIdentity.servedModelIDs {
            var config = CBv2MTPConfig(enabled: true)
            let on = SDKFeatureDefaults.applyMTPDefaults(
                to: &config, modelId: id, environment: [:], processEnvironment: [:])
            #expect(config.logitBiasSpeculation, "\(id)")
            #expect(
                on.contains(MTPLogitBiasRows.environmentKey) == CBv2MTPConfig.envLogitBiasSpeculation)
        }
        for id in [
            "thinkingmachines/inkling-2-mini", "gemma-4-26b-qat-4bit", "Qwen3.5-9B", "qwen3.5-35b-a3b",
            "qwen3.6-35b-a3b-vl-mtp-mxfp8", "EigenLabs/Qwen3.8-27B-4bit-mtp", "glm-5.3-flash",
            "nvidia-nemotron-3.5-super",
        ] {
            var config = CBv2MTPConfig(enabled: true)
            SDKFeatureDefaults.applyMTPDefaults(
                to: &config, modelId: id, environment: [:], processEnvironment: [:])
            #expect(!config.logitBiasSpeculation, "\(id)")
        }
    }

    /// Inkling's configuration as `EngineV2SlotFactory` builds it, run as the
    /// round driver runs it beside the loaded drafter: the opt-in takes effect.
    @Test func theOptInTakesEffectOnInklingsServingConfig() {
        let id = Inkling2ModelIdentity.upstreamModelID
        for cap in [7, 4, 1] {
            var config = Inkling2DSparkDrafter.defaultMTPConfig(maxDraftTokens: cap)
            config.acceptance = MTPAcceptancePolicy.resolve(
                global: nil, byModel: [:], modelID: id
            ).acceptance
            SDKFeatureDefaults.applyMTPDefaults(
                to: &config, modelId: id, environment: [:], processEnvironment: [:])
            let running = config.requiring(Inkling2DSparkDrafter.servingVerificationMode)
            #expect(running.effectiveLogitBiasSpeculation == CBv2MTPConfig.envLogitBiasSpeculation)
        }
    }

    @Test func theSummaryNamesTheBuilds() {
        let line = SDKFeatureDefaults.summary(
            environment: [:], injected: [], spansBuilds: [], grammarBuilds: [],
            logitBiasBuilds: Inkling2ModelIdentity.servedModelIDs)
        #expect(line?.contains(MTPLogitBiasRows.environmentKey) == true)
    }
}
