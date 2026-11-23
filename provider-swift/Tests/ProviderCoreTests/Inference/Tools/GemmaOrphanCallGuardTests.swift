import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

/// No tool-call close without an open call on Gemma 4 `auto` tool rows (`GemmaOrphanCallGuard`).
@Suite("Gemma orphan call guard")
struct GemmaOrphanCallGuardTests {
    private typealias F = StrictToolFixture
    private typealias T = GemmaPieceTestTokenizer

    private static let stops: Set<Int> = [1, 50, 106]
    private static let callOpen = 48, callClose = 49, toolResponse = 50, turnEnd = 106, eos = 1
    private static let thoughtOpen = 100, thoughtClose = 101
    private static let thought = T.id("thought"), hello = T.id("▁hello"), brace = T.id("{\"")
    private static let size = T.vocabularySize
    private static let tool = #"""
    [{"type":"function","function":{"name":"read","parameters":{"type":"object",
      "properties":{"path":{"type":"string"}},"required":["path"]}}}]
    """#

    private static func guardConstraint(_ mode: GemmaOrphanCallGuard.Mode, maxTokens: Int = 512) throws
        -> GemmaOrphanCallGuardConstraint {
        try GemmaOrphanCallGuardConstraint(guardMode: mode, vocabularySize: size, stopTokenIDs: stops,
                                           maxTokens: maxTokens)
    }

    /// Walks `tokens` through the mask and the transition: the last state (-1
    /// after a stop), or nil at the first token the guard refuses.
    private static func walk(_ tokens: [Int], _ constraint: GemmaOrphanCallGuardConstraint,
                             from start: Int? = nil) -> Int? {
        var state = start ?? constraint.initialState
        for token in tokens {
            guard state >= 0,
                  constraint.allowedTokenIDs(state: state, remainingTokens: 100).maskContains(token),
                  let next = constraint.nextState(state: state, tokenID: token) else { return nil }
            state = next
        }
        return state
    }

    @Test func theSwitchReadsOnStrictOrOff() {
        for raw in ["on", "ON", " 1 ", "true", "yes"] { #expect(GemmaOrphanCallGuard.mode(raw) == .on, "\(raw)") }
        #expect(GemmaOrphanCallGuard.mode("strict") == .strict)
        #expect(GemmaOrphanCallGuard.mode(" Strict\n") == .strict)
        for raw in [nil, "", "off", "0", "false", "no", "maybe"] as [String?] {
            #expect(GemmaOrphanCallGuard.mode(raw) == .off, "\(String(describing: raw))")
        }
        #expect(throws: (any Error).self) { try Self.guardConstraint(.off) }
    }

    /// Production's signature: a thought opened, the close with no call, the tool response.
    @Test func theAbortedCallIsUnreachable() throws {
        for mode in [GemmaOrphanCallGuard.Mode.on, .strict] {
            let constraint = try Self.guardConstraint(mode)
            #expect(Self.walk([Self.thoughtOpen, Self.thought, Self.callClose, Self.toolResponse], constraint) == nil)
            let afterThought = try #require(Self.walk([Self.thoughtOpen, Self.thought], constraint))
            #expect(!constraint.allowedTokenIDs(state: afterThought, remainingTokens: 10).maskContains(Self.callClose))
            #expect(constraint.nextState(state: afterThought, tokenID: Self.callClose) == nil)
            // Two closes in a row: the second has no call either.
            #expect(Self.walk([Self.callOpen, Self.hello, Self.callClose, Self.callClose], constraint) == nil)
        }
    }

    @Test func callsAndAnswersEndAsBefore() throws {
        for mode in [GemmaOrphanCallGuard.Mode.on, .strict] {
            let constraint = try Self.guardConstraint(mode)
            for tokens in [
                // A thought, a call, the tool response.
                [Self.thoughtOpen, Self.thought, Self.thoughtClose, Self.callOpen, Self.brace, Self.hello,
                 Self.callClose, Self.toolResponse],
                // Two calls in one turn, then the tool response.
                [Self.callOpen, Self.brace, Self.callClose, Self.callOpen, Self.hello, Self.callClose, Self.toolResponse],
                // Plain answers end on `<turn|>` or `<eos>`.
                [Self.hello, Self.hello, Self.turnEnd], [Self.thoughtOpen, Self.thought, Self.thoughtClose, Self.hello,
                                                         Self.turnEnd],
                [Self.hello, Self.eos], [Self.turnEnd],
                // A call followed by text, then the end of turn.
                [Self.callOpen, Self.hello, Self.callClose, Self.hello, Self.turnEnd],
            ] {
                #expect(Self.walk(tokens, constraint) == -1, "\(mode) \(tokens)")
            }
        }
    }

    @Test func strictKeepsTheToolResponseForAClosedCall() throws {
        let strict = try Self.guardConstraint(.strict)
        #expect(Self.walk([Self.hello, Self.toolResponse], strict) == nil)
        #expect(Self.walk([Self.callOpen, Self.hello, Self.toolResponse], strict) == nil)
        #expect(Self.walk([Self.callOpen, Self.hello, Self.callClose, Self.hello, Self.toolResponse], strict) == nil)
        #expect(Self.walk([Self.callOpen, Self.hello, Self.callClose, Self.toolResponse], strict) == -1)
        // `on` leaves the tool response as it is.
        let on = try Self.guardConstraint(.on)
        #expect(Self.walk([Self.hello, Self.toolResponse], on) == -1)
        #expect(Self.walk([Self.callOpen, Self.hello, Self.toolResponse], on) == -1)
    }

    /// Each state's mask is the vocabulary less the tokens it refuses, keyed
    /// by that set, the same on every call; nothing else differs.
    @Test func theMasksAreTheVocabularyLessTheRefusedTokens() throws {
        let all = Array(0..<Self.size)
        func less(_ refused: Int...) -> [Int] { all.filter { !refused.contains($0) } }
        let idle = GemmaOrphanCallGuardConstraint.idle, open = GemmaOrphanCallGuardConstraint.open
        let closed = GemmaOrphanCallGuardConstraint.closed
        let on = try Self.guardConstraint(.on), strict = try Self.guardConstraint(.strict)
        #expect(on.allowedTokenIDs(state: idle, remainingTokens: 1) == less(Self.callClose))
        #expect(on.allowedTokenIDs(state: open, remainingTokens: 1) == all)
        #expect(on.allowedTokenIDs(state: closed, remainingTokens: 1) == less(Self.callClose))
        #expect(strict.allowedTokenIDs(state: idle, remainingTokens: 1) == less(Self.callClose, Self.toolResponse))
        #expect(strict.allowedTokenIDs(state: open, remainingTokens: 1) == less(Self.toolResponse))
        #expect(strict.allowedTokenIDs(state: closed, remainingTokens: 1) == less(Self.callClose))
        // Equal sets share a key, different sets do not, and the key ignores the positive budget.
        #expect(on.maskCacheKey(state: idle, remainingTokens: 1) == on.maskCacheKey(state: closed, remainingTokens: 9))
        #expect(on.maskCacheKey(state: idle, remainingTokens: 1) == strict.maskCacheKey(state: closed, remainingTokens: 1))
        let keys = [on.maskCacheKey(state: open, remainingTokens: 1), on.maskCacheKey(state: idle, remainingTokens: 1),
                    strict.maskCacheKey(state: open, remainingTokens: 1),
                    strict.maskCacheKey(state: idle, remainingTokens: 1)]
        #expect(Set(keys.compactMap { $0 }).count == 4)
        #expect(on.allowedTokenIDs(state: idle, remainingTokens: 0).isEmpty)
        #expect(on.maskCacheKey(state: idle, remainingTokens: 0) == nil)
        #expect(on.allowedTokenIDs(state: 7, remainingTokens: 1).isEmpty)
        #expect(on.mode == .auto && Self.stops.contains(on.fallbackTokenID) && on.maxTokens == 512)
        #expect(on.allowsChainedDecode)
    }

    @Test func textInsideOrOutsideACallIsAFreeSpan() throws {
        let constraint = try Self.guardConstraint(.strict)
        let idle = GemmaOrphanCallGuardConstraint.idle, open = GemmaOrphanCallGuardConstraint.open
        for state in [idle, open] {
            #expect(constraint.isFreeSpan(state: state))
            #expect(constraint.isFreeSpanContinuation(state: state, tokenID: Self.hello))
            for token in [Self.callOpen, Self.callClose, Self.toolResponse, Self.turnEnd, Self.eos] {
                #expect(!constraint.isFreeSpanContinuation(state: state, tokenID: token), "\(state) \(token)")
            }
        }
        #expect(!constraint.isFreeSpan(state: GemmaOrphanCallGuardConstraint.closed))
        #expect(!constraint.isFreeSpanContinuation(state: GemmaOrphanCallGuardConstraint.closed, tokenID: Self.hello))
    }

    /// The loop guard's exit-thinking continuation starts where the row stood, not over.
    @Test func aContinuationKeepsTheRowsState() throws {
        let constraint = try Self.guardConstraint(.strict)
        let midCall = try #require(constraint.continuing(after: [Self.callOpen, Self.hello], maxTokens: 64))
        #expect(midCall.initialState == GemmaOrphanCallGuardConstraint.open && midCall.maxTokens == 64)
        #expect(midCall.guardMode == .strict)
        #expect(Self.walk([Self.callClose, Self.toolResponse], midCall) == -1)
        let afterClose = try #require(constraint.continuing(after: [Self.callOpen, Self.hello, Self.callClose],
                                                            maxTokens: 64))
        #expect(afterClose.initialState == GemmaOrphanCallGuardConstraint.closed)
        let plain = try #require(constraint.continuing(after: [Self.thoughtOpen, Self.thought, Self.thoughtClose],
                                                       maxTokens: 64))
        #expect(plain.initialState == GemmaOrphanCallGuardConstraint.idle)
        #expect(constraint.continuing(after: [Self.callClose], maxTokens: 64) == nil)
        #expect(constraint.continuing(after: [Self.hello, Self.turnEnd], maxTokens: 64) == nil)
        #expect(constraint.continuing(after: [], maxTokens: 0) == nil)
    }

    @Test func eligibility() throws {
        for (choice, modelType, mode, expected) in [
            (nil as String?, "gemma4", GemmaOrphanCallGuard.Mode.on, true),
            (#""auto""#, "gemma4_text", .strict, true),
            // Forced calls keep their grammar; `none` declares no call to make.
            (#""required""#, "gemma4", .on, false),
            (#"{"type":"function","function":{"name":"read"}}"#, "gemma4", .on, false),
            (#""none""#, "gemma4", .on, false),
            (nil, "gemma4_vision", .on, false), (nil, "qwen3_5", .on, false), (nil, "gemma4", .off, false),
        ] as [(String?, String, GemmaOrphanCallGuard.Mode, Bool)] {
            let (_, prepared) = try F.prepared(F.body(tools: Self.tool, choice: choice), modelType: modelType)
            #expect(GemmaOrphanCallGuard.isCandidate(prepared: prepared, modelType: modelType, mode: mode) == expected,
                    "\(String(describing: choice)) \(modelType) \(mode)")
        }
        let (_, toolFree) = try F.prepared(#"{"model":"m","messages":[{"role":"user","content":"hi"}]}"#,
                                           modelType: "gemma4")
        #expect(!GemmaOrphanCallGuard.isCandidate(prepared: toolFree, modelType: "gemma4", mode: .on))
    }

    @Test func theGuardIsBuiltForAnEligibleRequestOnly() throws {
        let handle = TokenizerHandle(T())
        func make(_ body: String, runs: Bool = true, width: Int? = Self.size, mode: GemmaOrphanCallGuard.Mode = .on,
                  tokenizer: TokenizerHandle? = nil) throws -> GemmaOrphanCallGuardConstraint? {
            let (request, prepared) = try F.prepared(body, modelType: "gemma4")
            return GemmaOrphanCallGuard.constraint(prepared: prepared, request: request, tokenizer: tokenizer ?? handle,
                modelType: "gemma4", maxTokens: 300, stopTokenIDs: Self.stops, runsTokenConstraints: runs,
                logitsWidth: width, mode: mode)
        }
        let auto = F.body(tools: Self.tool, choice: #""auto""#)
        let made = try #require(try make(auto))
        #expect(made.guardMode == .on && made.maxTokens == 300 && made.initialState == GemmaOrphanCallGuardConstraint.idle)
        #expect(try #require(try make(auto, mode: .strict)).guardMode == .strict)
        #expect(try make(auto, width: nil) != nil)
        #expect(try make(auto, runs: false) == nil)
        #expect(try make(auto, width: 1_000) == nil)
        #expect(try make(auto, mode: .off) == nil)
        var smaller = T()
        smaller.size = 1_000
        #expect(try make(auto, tokenizer: TokenizerHandle(smaller)) == nil)
        for penalty in [#""presence_penalty":0.5"#, #""frequency_penalty":0.2"#] {
            let body = String(auto.dropLast()) + "," + penalty + "}"
            #expect(try make(body) == nil, "\(penalty)")
        }
        #expect(try make(String(auto.dropLast()) + #","presence_penalty":0}"#) != nil)
    }

    /// The guard changes nothing about the loop guard: with or without it, the
    /// same guard and the same exit-thinking.
    @Test func theLoopGuardIsTheSameWithTheGuard() throws {
        let (request, prepared) = try F.prepared(F.body(tools: Self.tool, choice: #""auto""#), modelType: "gemma4")
        let exit = GenerationLoopExitThinking(openMarker: "<|channel>", closeMarker: "<channel|>",
            exitTokens: [Self.thoughtClose], exitText: "<channel|>", startsInside: false, record: GenerationLoopExitRecord())
        let without = GenerationLoopGuardPolicy.resolve(modelType: "gemma4", request: request, prepared: prepared,
            tokenConstraint: nil, setting: .modelTypes(["gemma4"]), exitThinking: exit)
        let with = GenerationLoopGuardPolicy.resolve(modelType: "gemma4", request: request, prepared: prepared,
            tokenConstraint: try Self.guardConstraint(.on), setting: .modelTypes(["gemma4"]), exitThinking: exit)
        #expect((without == nil) == (with == nil))
        #expect((without?.exitThinking == nil) == (with?.exitThinking == nil))
    }
}
