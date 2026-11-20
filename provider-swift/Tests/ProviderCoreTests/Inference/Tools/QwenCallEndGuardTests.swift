import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

/// No end of turn inside a Qwen 3.5–3.8 call frame (`QwenCallEndGuard`).
@Suite("Qwen call end guard")
struct QwenCallEndGuardTests {
    private typealias F = StrictToolFixture

    private static let writeFileTool = #"""
    [{"type":"function","function":{"name":"write_file","parameters":{"type":"object",
      "properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}}}]
    """#
    private static let head = "<tool_call>\n<function=write_file>\n<parameter=path>\nREADME.md\n</parameter>\n"
    private static let call = head + "<parameter=content>\n# T\n</parameter>\n</function>\n</tool_call>"

    /// Byte pieces, the pinned markers and the answer EOS: the production
    /// machine on a CPU-only vocabulary.
    private static func vocabulary() throws -> JSONAnswerVocabulary {
        let profile = QwenStrictToolGrammar.profile
        var pieces = [[UInt8]](repeating: [], count: profile.vocabularySize)
        for byte in 0..<256 { pieces[byte] = [UInt8(byte)] }
        pieces[300] = Array("</parameter>".utf8)
        pieces[301] = Array("hello world".utf8)
        pieces[302] = Array("x<".utf8)
        for token in profile.pieceTokens + profile.answerEOS { pieces[token.id] = Array(token.spelling.utf8) }
        return try JSONAnswerVocabulary(pieces: pieces, profile: profile, stopTokenIDs: F.stops)
    }

    private static func guardConstraint(reasoning: Bool = false) throws -> QwenCallEndGuardConstraint {
        try QwenCallEndGuardConstraint(vocabulary: vocabulary(), mode: .required, startsInReasoning: reasoning,
                                       maxTokens: 4096)
    }

    /// Walks `text` (markers as their added tokens, other bytes as byte
    /// pieces); nil at the first token the masks refuse.
    private static func walk(_ text: String, _ constraint: QwenCallEndGuardConstraint, from start: Int? = nil) -> Int? {
        var state = start ?? constraint.initialState
        for token in QwenByteTestTokenizer.tokens(text) {
            guard constraint.allowedTokenIDs(state: state, remainingTokens: 1_000).maskContains(token),
                  let next = constraint.nextState(state: state, tokenID: token) else { return nil }
            state = next
        }
        return state
    }

    private static func endsTurn(_ constraint: QwenCallEndGuardConstraint, after text: String) throws -> Bool {
        let state = try #require(walk(text, constraint), "\(text.debugDescription)")
        let mask = constraint.allowedTokenIDs(state: state, remainingTokens: 10)
        let allowed = F.stops.allSatisfy { mask.maskContains($0) }
        // The mask and the transition agree.
        #expect((constraint.nextState(state: state, tokenID: F.imEnd) == -1) == allowed, "\(text.debugDescription)")
        #expect(constraint.maskCacheKey(state: state, remainingTokens: 10) == (allowed ? 0 : 1))
        return allowed
    }

    @Test func noEndOfTurnInsideANamedFrame() throws {
        let constraint = try Self.guardConstraint()
        // Outside a frame, or before its function is named, the turn may end.
        for text in ["", "Sure.", "<tool_call>", "<tool_call>\n", "<tool_call>\n<func", Self.call, Self.call + "\n",
                     "x <tool_call> tags", "<tool_call>\n{\"name\": \"write_file\"", Self.head + "oops",
                     Self.head + "</function>\nDone.", "<tool_call>\n<function=>",
                     // `</tool_call>` inside a value is read as the model closing the call: released.
                     Self.head + "<parameter=content>\nx\n</function>\n</tool_call>",
                     Self.head + "<parameter=content>\na </tool_call>",
                     "<tool_call>\n<function=" + String(repeating: "n", count: 300)] {
            #expect(try Self.endsTurn(constraint, after: text), "\(text.debugDescription)")
        }
        // Inside it: a name, between parameters, a parameter name, a value (also
        // one holding marker spellings) and before `</tool_call>`.
        for text in ["<tool_call>\n<function=", "<tool_call><function=write", Self.head, Self.head + "<",
                     // A partial `</tool_call>` does not survive `</parameter>`.
                     Self.head + "<parameter=content>\na </tool_ca</parameter>\n",
                     Self.head + "</func", Self.head + "<parameter=cont", Self.head + "<parameter=content>\n# T",
                     Self.head + "<parameter=content>\n# T\n", Self.head + "<parameter=content>\n# T\n</param",
                     Self.head + "<parameter=content>\na </function> b <tool_call>\n<function=x> c",
                     Self.head + "</function>", Self.head + "</function>\n</tool"] {
            #expect(try !Self.endsTurn(constraint, after: text), "\(text.debugDescription)")
        }
        // ... and leaves exactly the boundary between parameters (states are interned).
        #expect(Self.walk(Self.head + "<parameter=content>\na </tool_ca</parameter>\n", constraint)
            == Self.walk(Self.head, constraint))
        // Each call of a parallel answer is held on its own.
        #expect(try !Self.endsTurn(constraint, after: Self.call + "\n" + Self.head))
        #expect(try Self.endsTurn(constraint, after: Self.call + "\n" + Self.call))
    }

    @Test func reasoningIsFreeUntilTheThoughtCloses() throws {
        let constraint = try Self.guardConstraint(reasoning: true)
        #expect(try Self.endsTurn(constraint, after: "Plan: " + Self.head + "<parameter=content>\nx"))
        #expect(try !Self.endsTurn(constraint, after: "Plan.</think>\n\n" + Self.head))
        #expect(try Self.endsTurn(constraint, after: "Plan.</think>\n\n" + Self.call))
    }

    /// Two masks: every piece (held) and every piece and stop (free), each the
    /// same on every call, and nothing else differs.
    @Test func theMasksAreTheVocabularyWithOrWithoutTheStops() throws {
        let vocabulary = try Self.vocabulary()
        let constraint = try QwenCallEndGuardConstraint(vocabulary: vocabulary, mode: .auto, startsInReasoning: false,
                                                        maxTokens: 64)
        let free = try #require(Self.walk("Sure.", constraint))
        let held = try #require(Self.walk(Self.head, constraint))
        #expect(constraint.allowedTokenIDs(state: free, remainingTokens: 1) == (vocabulary.pieceTokenIDs + F.stops).sorted())
        #expect(constraint.allowedTokenIDs(state: held, remainingTokens: 1) == vocabulary.pieceTokenIDs)
        #expect(constraint.allowedTokenIDs(state: held, remainingTokens: 0).isEmpty)
        #expect(constraint.mode == .auto && constraint.fallbackTokenID == vocabulary.fallbackTokenID)
        #expect(constraint.allowsChainedDecode)
    }

    /// Plain text in a value or outside a frame is drafted freely; a token
    /// that touches a marker, a stop and every structural position are not.
    @Test func freeSpansAreTextWithNoMarkerInProgress() throws {
        let constraint = try Self.guardConstraint()
        let content = try #require(Self.walk("Sure.", constraint))
        let value = try #require(Self.walk(Self.head + "<parameter=content>\n", constraint))
        let between = try #require(Self.walk(Self.head, constraint))
        for state in [content, value] {
            #expect(constraint.isFreeSpan(state: state))
            #expect(constraint.isFreeSpanContinuation(state: state, tokenID: 301))
            #expect(!constraint.isFreeSpanContinuation(state: state, tokenID: 302))
            #expect(!constraint.isFreeSpanContinuation(state: state, tokenID: F.imEnd))
        }
        #expect(!constraint.isFreeSpanContinuation(state: value, tokenID: 300))
        #expect(!constraint.isFreeSpan(state: between))
        // Mid `</tool_call>` in a value (`</t`: the `</parameter>` matcher is back at 0) is not a free span.
        let callClosing = try #require(Self.walk(Self.head + "<parameter=content>\n</t", constraint))
        #expect(!constraint.isFreeSpan(state: callClosing))
        #expect(!constraint.isFreeSpanContinuation(state: callClosing, tokenID: 301))
        // Previews intern nothing.
        let count = constraint.cachedStateCount
        _ = constraint.isFreeSpanContinuation(state: value, tokenID: 300)
        #expect(constraint.cachedStateCount == count)
    }

    @Test func eligibility() throws {
        for (choice, modelType, expected) in [
            (#""required""#, "qwen3_5_moe", true),
            (#"{"type":"function","function":{"name":"write_file"}}"#, "qwen3_5", true),
            // `auto` keeps its drafting: only forced calls fail when unfinished.
            (nil as String?, "qwen3_5", false), (#""auto""#, "qwen3_5_moe", false), (#""none""#, "qwen3_5", false),
            (#""required""#, "gpt_oss", false), (#""required""#, "gemma4", false),
        ] as [(String?, String, Bool)] {
            let (_, prepared) = try F.prepared(F.body(tools: Self.writeFileTool, choice: choice), modelType: modelType)
            #expect(QwenCallEndGuard.isCandidate(prepared: prepared, parser: .qwen35, modelType: modelType,
                enabled: true) == expected, "\(String(describing: choice)) \(modelType)")
        }
        let (_, prepared) = try F.prepared(F.body(tools: Self.writeFileTool, choice: #""required""#))
        #expect(!QwenCallEndGuard.isCandidate(prepared: prepared, parser: .qwen35, modelType: "qwen3_5", enabled: false))
        #expect(!QwenCallEndGuard.isCandidate(prepared: prepared, parser: .harmony, modelType: "qwen3_5", enabled: true))
    }

    @Test func theGuardIsBuiltForAnEligibleRequestOnly() throws {
        let (request, prepared) = try F.prepared(F.body(tools: Self.writeFileTool, choice: #""required""#))
        func make(thinking: Bool = false, runs: Bool = true) -> QwenCallEndGuardConstraint? {
            QwenCallEndGuard.constraint(prepared: prepared, request: request, parser: .qwen35, tokenizer: F.handle,
                modelType: "qwen3_5", defaultMaxTokens: 512, stopTokenIDs: F.stops,
                promptTokens: QwenByteTestTokenizer.tokens(QwenByteTestTokenizer.prompt(thinking: thinking)),
                runsTokenConstraints: runs, enabled: true)
        }
        let made = try #require(make())
        #expect(!made.startsInReasoning && made.mode == .required && made.maxTokens == 512)
        #expect(try #require(make(thinking: true)).startsInReasoning)
        #expect(make(runs: false) == nil)
    }
}
