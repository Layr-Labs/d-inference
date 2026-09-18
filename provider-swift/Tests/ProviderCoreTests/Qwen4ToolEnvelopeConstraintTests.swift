import Testing
@testable import ProviderCore

@Suite("Native Qwen4 tool envelope terminal guard")
struct Qwen4ToolEnvelopeConstraintTests {
    private let pieces = ["<eos>", "<tool_call>", "\n<function=record_text>\n<parameter=text>\n",
                          "<tool_call>{\"not\":\"an invocation\"}</tool_call> plus ",
                          "<think>literal example</think>", "</parameter>\n</function>\n</tool_call>",
                          "<tool_", "call>", "{\"name\":\"f\",\"arguments\":{\"x\":\"",
                          "</tool_call>", "\"}}", "plain text", "<", "b", "�"]

    @Test func prematureEOSIsBlockedWithoutChangingPayloadTokens() throws {
        let vocab = Qwen4ToolFramingVocabulary(pieces: pieces.map(Optional.some), stopTokenIDs: [0])
        let guardMachine = try Qwen4ToolEnvelopeConstraint(mode: .required, maxTokens: 20, vocabulary: vocab)
        var state = guardMachine.initialState
        #expect(guardMachine.allowedTokenIDs(state: state, remainingTokens: 20).contains(0))
        for token in [1, 2, 3, 4] {
            let next = try #require(guardMachine.nextState(state: state, tokenID: token))
            #expect(guardMachine.nextState(state: state, tokenID: token) == next)
            state = next
            #expect(!guardMachine.allowedTokenIDs(state: state, remainingTokens: 10).contains(0))
            #expect(guardMachine.nextState(state: state, tokenID: 0) == nil)
            #expect(guardMachine.allowedTokenIDs(state: state, remainingTokens: 10) == Array(1..<pieces.count))
        }
        state = try #require(guardMachine.nextState(state: state, tokenID: 5))
        #expect(guardMachine.allowedTokenIDs(state: state, remainingTokens: 1).contains(0))
        #expect(guardMachine.nextState(state: state, tokenID: 0) == -1)
    }

    @Test func splitOpenAndJSONLiteralCloseRemainBoundedAndReplayable() throws {
        let vocab = Qwen4ToolFramingVocabulary(pieces: pieces.map(Optional.some), stopTokenIDs: [0])
        let machine = try Qwen4ToolEnvelopeConstraint(mode: .required, maxTokens: 20, vocabulary: vocab)
        var state = 0
        for token in [6, 7, 8, 9] {
            state = try #require(machine.nextState(state: state, tokenID: token))
            #expect(!machine.allowedTokenIDs(state: state, remainingTokens: 1).contains(0))
        }
        state = try #require(machine.nextState(state: state, tokenID: 10))
        #expect(!machine.allowedTokenIDs(state: state, remainingTokens: 1).contains(0))
        state = try #require(machine.nextState(state: state, tokenID: 9))
        #expect(machine.allowedTokenIDs(state: state, remainingTokens: 1).contains(0))
        #expect(machine.allowedTokenIDs(state: state, remainingTokens: 0).isEmpty)
        #expect(machine.allowedTokenIDs(state: -1, remainingTokens: 2).isEmpty)
        #expect(machine.nextState(state: 0, tokenID: pieces.count) == nil)
    }

    @Test func nativeByteLevelProjectionPreservesOnlyFramingMeaning() {
        #expect(Qwen4ToolFramingVocabulary.framingProjection("ĠaĊ<tool_call>\\\"") == " a\n<tool_call>\\\"")
        #expect(!Qwen4ToolFramingVocabulary.framingProjection("é雪").contains("<"))
    }
}
