import MLXLMCommon
import ProviderCoreFoundation
import Testing
@testable import ProviderCore

/// The SDK reads `DARKBLOOM_MTP_LOGPROB_ROWS` once per process
/// (`CBv2MTPConfig.envLogprobSpeculation`): on the builds that opt in, rows
/// that request logprobs speculate unless it is `0`. The rollback must reach a
/// background provider too, so the LaunchAgent forwards the operator's value.
@Suite("MTP logprob-row switch reaches the LaunchAgent")
struct MTPLogprobRowsSwitchTests {
    @Test func rollbackIsForwarded() {
        let key = MTPLogprobRows.environmentKey
        #expect(key == "DARKBLOOM_MTP_LOGPROB_ROWS")
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key))
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "0"])[key] == "0")
        #expect(LaunchAgent.passthroughEnvironment(from: [:])[key] == nil)
    }

    @Test func onlyInklingOptsIn() {
        for id in Inkling2ModelIdentity.servedModelIDs {
            var config = CBv2MTPConfig(enabled: true)
            let on = SDKFeatureDefaults.applyMTPDefaults(
                to: &config, modelId: id, environment: [:], processEnvironment: [:])
            #expect(config.logprobSpeculation, "\(id)")
            #expect(on.contains(MTPLogprobRows.environmentKey) == CBv2MTPConfig.envLogprobSpeculation)
        }
        for id in [
            "thinkingmachines/inkling-2-mini", "gemma-4-26b-qat-4bit", "Qwen3.5-9B", "qwen3.5-35b-a3b",
            "qwen3.6-35b-a3b-vl-mtp-mxfp8", "EigenLabs/Qwen3.8-27B-4bit-mtp", "glm-5.3-flash",
            "nvidia-nemotron-3.5-super",
        ] {
            var config = CBv2MTPConfig(enabled: true)
            SDKFeatureDefaults.applyMTPDefaults(
                to: &config, modelId: id, environment: [:], processEnvironment: [:])
            #expect(!config.logprobSpeculation, "\(id)")
        }
    }

    /// The SDK takes the opt-in only on a target whose verify logits equal
    /// one-token decode's, under exact acceptance: Inkling's drafter
    /// requires `.rectangularExact`, and typical acceptance keeps logprob
    /// rows target-only.
    @Test func theOptInNeedsExactAcceptance() {
        var config = CBv2MTPConfig(enabled: true, verificationMode: .rectangularExact)
        SDKFeatureDefaults.applyMTPDefaults(
            to: &config, modelId: Inkling2ModelIdentity.upstreamModelID, environment: [:],
            processEnvironment: [:])
        #expect(config.effectiveLogprobSpeculation == CBv2MTPConfig.envLogprobSpeculation)
        config.acceptance = .typical(delta: 0.2)
        #expect(!config.effectiveLogprobSpeculation)
    }

    @Test func startupSummaryNamesTheBuild() {
        let line = SDKFeatureDefaults.summary(environment: [:], injected: [])
        #expect(
            line?.contains("DARKBLOOM_MTP_LOGPROB_ROWS (\(Inkling2ModelIdentity.upstreamModelID))")
                == CBv2MTPConfig.envLogprobSpeculation)
    }
}
