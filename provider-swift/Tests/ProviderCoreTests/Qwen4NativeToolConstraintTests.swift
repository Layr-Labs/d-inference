import Testing
import MLXLMCommon
@testable import ProviderCore

@Suite("Native Qwen4 forced-tool framing boundaries")
struct Qwen4NativeToolConstraintTests {
    private let pieces = ["<eos>", "<tool_call>", "<function=add><parameter=a>",
        "literal <think>value</think> and <tool_call>data</tool_call>",
        "</parameter></function></tool_call>", "</think>", "<think>", "add(a=7)", "\n",
        "<tool_", "call>", "</parameter></function></tool_call>bad", "</think>bad"]

    private func make(prefix: String, parallel: Bool = true, mode: ToolConstraintMode = .required,
                      names: Set<String> = ["add"], tokenPieces: [String]? = nil) throws -> Qwen4NativeToolConstraint {
        try Qwen4NativeToolConstraint(mode: mode, maxTokens: 64,
            vocabulary: Qwen4ToolFramingVocabulary(pieces: (tokenPieces ?? pieces).map(Optional.some), stopTokenIDs: [0]),
            nativePrefix: prefix, allowsParallel: parallel, allowedToolNames: names)
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

    @Test func freshToolFrameRejectsProseAndUndeclaredHeaders() throws {
        let pieces = ["<eos>", "<tool_call>", "\n", "? Wait", "<function=add>",
            "<function=other>", "<function=addExtra>", "<think>", "</tool_call>", " \n? Wait"]
        let probe = try make(prefix: "<think></think>", tokenPieces: pieces)
        let state = try #require(probe.nextState(state: 0, tokenID: 1))
        #expect(Set(probe.allowedTokenIDs(state: state, remainingTokens: 64)) == [2, 4])
        for id in pieces.indices {
            #expect(probe.allowedTokenIDs(state: state, remainingTokens: 64).contains(id)
                == (probe.nextState(state: state, tokenID: id) != nil))
        }
    }

    @Test func functionHeaderCanSpanTokensWithoutAdmittingProse() throws {
        let pieces = ["<eos>", "<tool_", "call>\n<func", "tion=", "ad", "d>",
            "? Wait", "dExtra>", "<parameter=a>literal <function=other> <|im_start|> <think>\n",
            "</parameter></function></tool_call>"]
        let probe = try make(prefix: "<think></think>", tokenPieces: pieces)
        var state = 0
        for token in [1, 2, 3, 4, 5, 8, 9] {
            let allowed = Set(probe.allowedTokenIDs(state: state, remainingTokens: 64))
            for id in pieces.indices {
                #expect(allowed.contains(id) == (probe.nextState(state: state, tokenID: id) != nil))
            }
            state = try #require(probe.nextState(state: state, tokenID: token))
        }
        #expect(probe.nextState(state: state, tokenID: 0) == -1)
    }

    @Test func namedChoiceRestrictsNativeHeaderButRequiredAllowsEachDeclaredName() throws {
        let pieces = ["<eos>", "<tool_call>", "<function=add>", "<function=adder>",
            "<function=other>", "<function=add_2>"]
        for mode in [ToolConstraintMode.required, .named("add")] {
            let probe = try make(prefix: "<think></think>", mode: mode,
                names: ["add", "adder", "add_2"], tokenPieces: pieces)
            let state = try #require(probe.nextState(state: 0, tokenID: 1))
            let expected: Set<Int> = mode == .required ? [2, 3, 5] : [2]
            #expect(Set(probe.allowedTokenIDs(state: state, remainingTokens: 64)) == expected)
        }
    }

    @Test func framedJSONAndItsLiteralMarkersRemainSupported() throws {
        let pieces = ["<eos>", "<tool_call>\n", "{", "\"name\":\"add\",\"arguments\":{\"a\":\"",
            "literal </tool_call> <think> <function=other> \\\"quoted\\\"", "\"}}", "</tool_call>",
            "? Wait", "<function=add><parameter=a>", "1</parameter></function></tool_call>"]
        let probe = try make(prefix: "<think></think>", tokenPieces: pieces)
        var state = 0
        for token in [1, 2, 3, 4, 5, 6] {
            #expect(probe.nextState(state: state, tokenID: 0) == nil)
            state = try #require(probe.nextState(state: state, tokenID: token))
        }
        #expect(probe.nextState(state: state, tokenID: 0) == -1)
        state = try #require(probe.nextState(state: state, tokenID: 1))
        // The next parallel frame has a fresh header boundary, not an opaque body.
        #expect(probe.nextState(state: state, tokenID: 7) == nil)
        for token in [8, 9] { state = try #require(probe.nextState(state: state, tokenID: token)) }
        #expect(probe.nextState(state: state, tokenID: 0) == -1)
    }

    @Test func invalidOrMissingFunctionNamesFailClosed() {
        #expect(throws: ToolConstraintSchemaError.self) { try make(prefix: "<think></think>", names: []) }
        #expect(throws: ToolConstraintSchemaError.self) { try make(prefix: "<think></think>", names: ["bad>name"]) }
        #expect(throws: ToolConstraintSchemaError.self) {
            try make(prefix: "<think></think>", mode: .named("missing"))
        }
    }
}
