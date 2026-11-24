import MLXLLM
import MLXLMCommon
import Testing
@testable import ProviderCore

/// `DARKBLOOM_INKLING_MTP_COUPLED` turns coupled drafting
/// (`CBv2MTPConfig.coupledProposals`) on for the served Inkling 2 identities
/// (`Inkling2MTPProfilePolicy.coupledProposals`). Off by default; never on for
/// another identity. Output is unchanged either way (the SDK's exact
/// acceptance); only acceptance can move.
@Suite("Inkling 2 MTP coupled drafting switch")
struct Inkling2MTPCoupledSwitchTests {
    private let key = Inkling2MTPProfilePolicy.coupledKey
    private var served: String { Inkling2ModelIdentity.upstreamModelID }

    @Test func offByDefault() {
        #expect(key == "DARKBLOOM_INKLING_MTP_COUPLED")
        #expect(!Inkling2MTPProfilePolicy.coupledByDefault)
        #expect(Inkling2ModelIdentity.isServedModelID(served))
        for environment in [[:], [key: ""], [key: "maybe"]] {
            #expect(!Inkling2MTPProfilePolicy.coupledProposals(modelID: served, environment: environment))
        }
        let config = Inkling2MTPProfilePolicy.engineConfig(
            maxDraft: Inkling2MTPProfilePolicy.maxDraftTokens(environment: [:]))
        #expect(!config.coupledProposals)
    }

    @Test(arguments: ["1", "true", "YES", " on "])
    func onWordsTurnItOnForTheServedModel(raw: String) {
        #expect(Inkling2MTPProfilePolicy.coupledProposals(modelID: served, environment: [key: raw]))
    }

    @Test(arguments: ["0", "false", "no", "OFF"])
    func offWordsKeepItOff(raw: String) {
        #expect(!Inkling2MTPProfilePolicy.coupledProposals(modelID: served, environment: [key: raw]))
    }

    @Test(arguments: ["gemma-4-26b-qat-4bit", "glm-5.3-flash", "Qwen3.5-9B", "thinkingmachines/inkling-2-mini"])
    func otherModelsNeverCouple(modelID: String) {
        #expect(!Inkling2MTPProfilePolicy.coupledProposals(modelID: modelID, environment: [key: "1"]))
    }

    @Test func theProfileCarriesTheSwitchAndNothingElseMoves() {
        let cap = Inkling2MTPProfilePolicy.maxDraftTokens(environment: [:])
        let on = Inkling2MTPProfilePolicy.engineConfig(maxDraft: cap, coupled: true)
        let off = Inkling2DSparkDrafter.defaultMTPConfig()
        #expect(on.coupledProposals)
        #expect(on.maxDraftTokens == off.maxDraftTokens)
        #expect(on.maxSpeculativeBatch == off.maxSpeculativeBatch)
        #expect(on.fixedDraftTokens == off.fixedDraftTokens)
        #expect(on.maxAutomaticRectangularTokens == off.maxAutomaticRectangularTokens)
        #expect(on.costCurveDepthSelection == off.costCurveDepthSelection)
        let capped = Inkling2MTPProfilePolicy.engineConfig(
            maxDraft: Inkling2MTPProfilePolicy.maxDraftTokens(environment: [Inkling2MTPProfilePolicy.maxDraftKey: "3"]),
            coupled: true)
        #expect(capped.coupledProposals && capped.maxDraftTokens == 3)
    }

    @Test func theSwitchReachesABackgroundProvider() {
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key))
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "1"])[key] == "1")
        #expect(LaunchAgent.passthroughEnvironment(from: [:])[key] == nil)
    }
}
