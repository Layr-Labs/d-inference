import Foundation
import ProviderCore
import Testing

@Suite
struct CBv2SchedulerBudgetEnvTests {
    @Test
    func unsetKeepsServingDefaults() {
        let tuning = EngineV2Factory.effectiveSchedulerTuning(environment: [:])
        #expect(tuning.prefillChunkSize == 512)
        #expect(tuning.maxBatchedTokensPerStep == 2048)
        #expect(tuning.soloPrefillStripeTokens == 2048)
    }

    @Test
    func positiveOverrideWins() {
        let tuning = EngineV2Factory.effectiveSchedulerTuning(environment: [
            EngineV2Factory.maxBatchedTokensKey: "4096",
            EngineV2Factory.prefillChunkKey: "1024",
        ])
        #expect(tuning.prefillChunkSize == 1024)
        #expect(tuning.maxBatchedTokensPerStep == 4096)
        #expect(tuning.soloPrefillStripeTokens == 2048)
    }

    @Test
    func junkAndNonPositiveAreIgnored() {
        for raw in ["0", "-1", "nope", ""] {
            let tuning = EngineV2Factory.effectiveSchedulerTuning(environment: [
                EngineV2Factory.maxBatchedTokensKey: raw,
                EngineV2Factory.prefillChunkKey: raw,
            ])
            #expect(tuning.prefillChunkSize == 512)
            #expect(tuning.maxBatchedTokensPerStep == 2048)
        }
    }

    @Test
    func soloStripeResolvesAfterEffectiveChunk() {
        let disarmedDefault = EngineV2Factory.effectiveSchedulerTuning(environment: [
            EngineV2Factory.prefillChunkKey: "4096",
        ])
        #expect(disarmedDefault.prefillChunkSize == 4096)
        #expect(disarmedDefault.soloPrefillStripeTokens == nil)

        let explicit = EngineV2Factory.effectiveSchedulerTuning(environment: [
            EngineV2Factory.prefillChunkKey: "4096",
            EngineV2Factory.soloPrefillStripeKey: "8192",
        ])
        #expect(explicit.soloPrefillStripeTokens == 8192)
    }

    @Test
    func surroundingWhitespaceIsAccepted() {
        let tuning = EngineV2Factory.effectiveSchedulerTuning(environment: [
            EngineV2Factory.maxBatchedTokensKey: " 4096\n",
            EngineV2Factory.prefillChunkKey: "\t1024 ",
        ])
        #expect(tuning.prefillChunkSize == 1024)
        #expect(tuning.maxBatchedTokensPerStep == 4096)
    }
}
