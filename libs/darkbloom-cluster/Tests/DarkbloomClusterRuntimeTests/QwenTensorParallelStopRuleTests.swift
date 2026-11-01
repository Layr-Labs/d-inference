import Testing
@testable import DarkbloomClusterRuntime

struct QwenTensorParallelStopRuleTests {
    /// A rank whose pages could not grow stops both ranks at the request's
    /// length (its slot crosses as `length`); a client stop's slot wins.
    @Test func aLengthStopCrossesAsLengthAndAClientStopWins() {
        typealias Rule = QwenTensorParallelStopRule
        #expect(Rule.stop(slot: Rule.lengthStop(keep: 37)) == (37, .length))
        #expect(Rule.stop(slot: 12) == (12, .clientStop))
        #expect(Rule.stop(slot: [Rule.lengthStop(keep: 40), 12].min()!) == (12, .clientStop))
        #expect(Rule.stop(slot: Rule.lengthStop(keep: 131_072)) == (131_072, .length))
        #expect(Rule.reconcile(rank: 1, localFinish: .length, localCount: 37, localStopped: true,
            rank0Finish: .length, rank0Count: 37) == (.length, 37))
    }
}
