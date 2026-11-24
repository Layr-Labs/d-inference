import MLXLLM
import MLXLMCommon
import Testing
@testable import ProviderCore

/// `DARKBLOOM_INKLING_MTP_MAX_DRAFT` caps Inkling 2's drafts per MTP round
/// (`Inkling2MTPProfilePolicy`): unset keeps the drafter's whole block (7), a
/// whole number is clamped to 1...7, anything else keeps 7 and is reported.
@Suite("Inkling 2 MTP max draft override")
struct Inkling2MTPMaxDraftTests {
    private let key = Inkling2MTPProfilePolicy.maxDraftKey

    @Test func unsetOrBlankKeepsTheShippedProfile() {
        #expect(key == "DARKBLOOM_INKLING_MTP_MAX_DRAFT")
        for environment in [[:], [key: ""], [key: "  "]] {
            let cap = Inkling2MTPProfilePolicy.maxDraftTokens(environment: environment)
            #expect(cap == .init(tokens: 7, unrecognized: nil))
            let config = Inkling2MTPProfilePolicy.engineConfig(maxDraft: cap)
            let shipped = Inkling2DSparkDrafter.defaultMTPConfig()
            #expect(config.maxDraftTokens == shipped.maxDraftTokens)
            #expect(config.maxAutomaticRectangularTokens == shipped.maxAutomaticRectangularTokens)
            #expect(config.fixedDraftTokens == nil)
            #expect(config.costCurveDepthSelection)
        }
    }

    @Test(arguments: [("4", 4), ("3", 3), ("2", 2), (" 5 ", 5), ("7", 7), ("1", 1)])
    func aWholeNumberSetsTheCap(raw: String, tokens: Int) {
        let cap = Inkling2MTPProfilePolicy.maxDraftTokens(environment: [key: raw])
        #expect(cap == .init(tokens: tokens, unrecognized: nil))
        let config = Inkling2MTPProfilePolicy.engineConfig(maxDraft: cap)
        #expect(config.enabled)
        #expect(config.maxDraftTokens == tokens)
        // Still adaptive below the cap, with the verify envelope of that depth.
        #expect(config.fixedDraftTokens == nil)
        #expect(config.maxAutomaticRectangularTokens == 8 * (tokens + 1))
        #expect(config.maxSpeculativeBatch == 8)
    }

    @Test(arguments: [("0", 1), ("-3", 1), ("8", 7), ("64", 7)])
    func outOfRangeValuesAreClamped(raw: String, tokens: Int) {
        let cap = Inkling2MTPProfilePolicy.maxDraftTokens(environment: [key: raw])
        #expect(cap == .init(tokens: tokens, unrecognized: nil))
        #expect(Inkling2MTPProfilePolicy.engineConfig(maxDraft: cap).maxDraftTokens == tokens)
    }

    @Test(arguments: ["four", "4.5", "3x", "on"])
    func otherValuesKeepSevenAndAreReported(raw: String) {
        let cap = Inkling2MTPProfilePolicy.maxDraftTokens(environment: [key: raw])
        #expect(cap == .init(tokens: 7, unrecognized: raw))
    }

    @Test func theOverrideReachesABackgroundProvider() {
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key))
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "3"])[key] == "3")
        #expect(LaunchAgent.passthroughEnvironment(from: [:])[key] == nil)
    }
}
