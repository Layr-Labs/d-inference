import Testing
import MLXLMCommon
@testable import ProviderCore

@Suite("Native Qwen4 forced-tool framing boundaries")
struct Qwen4NativeToolConstraintTests {
    private let pieces = ["<eos>", "<tool_call>", "<function=add><parameter=a>",
        "literal <think>value</think> and <tool_call>data</tool_call>",
        "</parameter></function></tool_call>", "</think>", "<think>", "add(a=7)", "\n",
        "<tool_", "call>", "</parameter></function></tool_call>bad", "</think>bad"]

    private func make(prefix: String, parallel: Bool = true) throws -> Qwen4NativeToolConstraint {
        try Qwen4NativeToolConstraint(mode: .required, maxTokens: 64,
            vocabulary: Qwen4ToolFramingVocabulary(pieces: pieces.map(Optional.some), stopTokenIDs: [0]),
            nativePrefix: prefix, allowsParallel: parallel)
    }

    @Test func offNeverAdmitsProseOrReasoningAndPayloadRemainsOpaque() throws {
        let probe = try make(prefix: "<think></think>")
        var state = 0
        #expect(Set(probe.allowedTokenIDs(state: state, remainingTokens: 64)) == [1, 8, 9])
        for token in [9, 10, 2, 3] {
            state = try #require(probe.nextState(state: state, tokenID: token))
        }
        #expect(!probe.allowedTokenIDs(state: state, remainingTokens: 64).contains(11))
        #expect(probe.nextState(state: state, tokenID: 11) == nil)
        state = try #require(probe.nextState(state: state, tokenID: 4))
        #expect(probe.nextState(state: state, tokenID: 0) == -1)
        #expect(probe.nextState(state: state, tokenID: 7) == nil)
        #expect(probe.nextState(state: state, tokenID: 1) != nil)
    }

    @Test func reasoningIsNativeAndCannotSatisfyARequiredCall() throws {
        let probe = try make(prefix: "<think>")
        var state = 0
        for token in [6, 1, 2, 3, 4, 5, 7] {
            state = try #require(probe.nextState(state: state, tokenID: token))
            #expect(!probe.allowedTokenIDs(state: state, remainingTokens: 64).contains(0))
        }
        #expect(!probe.allowedTokenIDs(state: state, remainingTokens: 64).contains(12))
        state = try #require(probe.nextState(state: state, tokenID: 5))
        #expect(probe.nextState(state: state, tokenID: 7) == nil)
        for token in [1, 2, 3, 4] { state = try #require(probe.nextState(state: state, tokenID: token)) }
        #expect(probe.nextState(state: state, tokenID: 0) == -1)
    }

    @Test func allowedTokensAndTransitionsAgreeAtEveryVisitedState() throws {
        for prefix in ["<think>", "<think></think>"] {
            let probe = try make(prefix: prefix, parallel: false)
            var state = 0
            let path = prefix == "<think>" ? [7, 5, 9, 10, 2, 3, 4] : [9, 10, 2, 3, 4]
            for token in path {
                let allowed = Set(probe.allowedTokenIDs(state: state, remainingTokens: 64))
                for id in pieces.indices { #expect(allowed.contains(id) == (probe.nextState(state: state, tokenID: id) != nil)) }
                state = try #require(probe.nextState(state: state, tokenID: token))
            }
            #expect(probe.nextState(state: state, tokenID: 1) == nil)
            #expect(probe.allowedTokenIDs(state: state, remainingTokens: 0).isEmpty)
        }
    }
}
