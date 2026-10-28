import Foundation
import Testing
@testable import DarkbloomClusterRuntime

// Model-free: a solo GLM tensor-parallel request no longer reserves its whole
// output's pages up front. It opens with its prompt and one 1,024-token
// granule and, before each step or round built, keeps the context it needs
// plus 64 tokens reserved, growing by a granule (never past its own length; no
// context cap). A refused growth ends the request at `length` through the
// per-step stop slot (`QwenTensorParallelStopRule.lengthStop`), as Qwen tensor
// parallel does.
@Suite("GLM tensor-parallel pages grow on demand")
struct GLM5NextTensorParallelPagedGrowthTests {
    typealias Runtime = GLM5NextTensorParallelResidentRuntime

    @Test func aRequestOpensWithItsPromptAndOneGranule() {
        #expect(Runtime.pageGrowthTokens == 1024 && Runtime.pageGrowthMargin == 64)
        #expect(Runtime.initialPageTokens(promptCount: 31_500, maximumTokens: 31_500 + 65_536) == 32_524)
        #expect(Runtime.initialPageTokens(promptCount: 900, maximumTokens: 1_000) == 1_000)
        // No growth while the margin is covered, or at the request's length.
        #expect(Runtime.pageGrowthTarget(tokens: 2_048, needed: 1_984, limit: 10_000) == nil)
        #expect(Runtime.pageGrowthTarget(tokens: 1_000, needed: 990, limit: 1_000) == nil)
        // A granule on, never past the length.
        #expect(Runtime.pageGrowthTarget(tokens: 2_048, needed: 1_985, limit: 10_000) == 3_072)
        #expect(Runtime.pageGrowthTarget(tokens: 2_048, needed: 1_985, limit: 2_500) == 2_500)
    }

    /// The decode loop's growth points: every context a step or round needs,
    /// plus the margin, is covered after at most one growth; growths are a
    /// granule apart and reach the request's length, however long (1M).
    @Test(arguments: [(31_500, 65_536), (7, 24), (1_000_000, 48_576), (12_400, 1_024), (300, 1_025)])
    func everyStepIsCoveredAndGrowthReachesTheLength(prompt: Int, outputs: Int) {
        let limit = prompt + outputs
        var tokens = Runtime.initialPageTokens(promptCount: prompt, maximumTokens: limit)
        var growths = 0
        for index in 0 ..< outputs - 1 {
            let needed = prompt + index + 2
            if let target = Runtime.pageGrowthTarget(tokens: tokens, needed: needed, limit: limit) {
                #expect(target > tokens && target <= limit)
                #expect(target == limit || target - tokens == Runtime.pageGrowthTokens)
                tokens = target; growths += 1
            }
            #expect(needed + Runtime.pageGrowthMargin <= tokens || tokens == limit)
        }
        #expect(tokens <= limit)
        #expect(growths <= (outputs + Runtime.pageGrowthTokens - 1) / Runtime.pageGrowthTokens)
    }

    /// The stop slot a refused growth sends names `length` and the tokens to
    /// keep; a client stop's smaller slot wins after the same step.
    @Test func aRefusedGrowthEndsAtLengthThroughTheStopSlot() {
        let slot = QwenTensorParallelStopRule.lengthStop(keep: 4_321)
        #expect(QwenTensorParallelStopRule.stop(slot: slot) == (keep: 4_321, finish: .length))
        #expect(QwenTensorParallelStopRule.stop(slot: 4_320) == (keep: 4_320, finish: .clientStop))
        #expect(min(slot, 4_322) == 4_322)
    }
}
