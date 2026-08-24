import Foundation
import ProviderCore
import Testing

@Suite
struct CBv2SchedulerBudgetEnvTests {
    @Test
    func unsetKeepsServingDefaults() {
        #expect(
            EngineV2Factory.positiveIntEnv(
                EngineV2Factory.maxBatchedTokensKey,
                default: 2048,
                environment: [:]) == 2048)
        #expect(
            EngineV2Factory.positiveIntEnv(
                EngineV2Factory.prefillChunkKey,
                default: 512,
                environment: [:]) == 512)
    }

    @Test
    func positiveOverrideWins() {
        #expect(
            EngineV2Factory.positiveIntEnv(
                EngineV2Factory.maxBatchedTokensKey,
                default: 2048,
                environment: [EngineV2Factory.maxBatchedTokensKey: "4096"]) == 4096)
        #expect(
            EngineV2Factory.positiveIntEnv(
                EngineV2Factory.prefillChunkKey,
                default: 512,
                environment: [EngineV2Factory.prefillChunkKey: "1024"]) == 1024)
    }

    @Test
    func junkAndNonPositiveAreIgnored() {
        for raw in ["0", "-1", "nope", ""] {
            #expect(
                EngineV2Factory.positiveIntEnv(
                    EngineV2Factory.maxBatchedTokensKey,
                    default: 2048,
                    environment: [EngineV2Factory.maxBatchedTokensKey: raw]) == 2048)
        }
    }
}
