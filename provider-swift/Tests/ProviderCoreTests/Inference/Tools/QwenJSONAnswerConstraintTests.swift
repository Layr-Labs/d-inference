import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

/// Synthetic Qwen-shaped vocabulary for the production machine: single bytes
/// at ids 0...255, optional multi-byte pieces from 256, the pinned think markers
/// at 248068/248069 and terminators at 248044/248046. Every other id up to the
/// model's padded 248,320 has no piece.
enum QwenAnswerFixture {
    static let profile = JSONAnswerProfile.qwen35
    static let stops: Set<Int> = [248044, 248046]
    static let endOfText = 248044, imStart = 248045, imEnd = 248046, toolCall = 248058
    static let think = 248068, thinkClose = 248069

    static let schema = #"""
    {"type":"object","properties":{
      "tables_used":{"type":"array","items":{"type":"string"},"maxItems":3},
      "count":{"type":"integer"},"label":{"type":"string","enum":["a","b"]},
      "note":{"type":["string","null"]}},
     "required":["tables_used","count"],"additionalProperties":false}
    """#
    static let tools = #"""
    [{"type":"function","function":{"name":"weather","parameters":{"type":"object",
      "properties":{"city":{"type":"string"}}}}}]
    """#
    static let jsonObject = #"{"type":"json_object"}"#

    static func schemaFormat(_ schema: String) -> String {
        #"{"type":"json_schema","json_schema":{"name":"out","schema":"# + schema + "}}"
    }

    static func request(format: String?, tools: String? = nil, choice: String? = nil, parser: String? = "qwen3",
                        maxTokens: Int = 64, image: Bool = false) throws -> OpenAIChatCompletionRequest {
        let content = image
            ? #"[{"type":"text","text":"hi"},{"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}}]"#
            : #""hi""#
        var body = #"{"model":"EigenLabs/Qwen3.5-9B-MLX-4bit-mtp","messages":[{"role":"user","content":"#
            + content + #"}],"max_tokens":\#(maxTokens)"#
        if let format { body += #","response_format":"# + format }
        if let tools { body += #","tools":"# + tools }
        if let choice { body += #","tool_choice":"# + choice }
        if let parser { body += #","reasoning_parser":""# + parser + #"""# }
        return try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: Data((body + "}").utf8))
    }

    static func answerFormat(_ format: String) throws -> JSONAnswerFormat {
        let responseFormat = try #require(try request(format: format).responseFormat)
        return try JSONAnswerFormat(responseFormat, forbidding: profile.contentMarkers, family: profile.family)
    }

    static func vocabulary(extra: [String] = [], extraBytes: [[UInt8]] = []) throws -> JSONAnswerVocabulary {
        var pieces = [[UInt8]](repeating: [], count: profile.vocabularySize)
        for byte in 0...255 { pieces[byte] = [UInt8(byte)] }
        for (offset, piece) in (extra.map { Array($0.utf8) } + extraBytes).enumerated() { pieces[256 + offset] = piece }
        pieces[think] = Array("<think>".utf8)
        pieces[thinkClose] = Array("</think>".utf8)
        return try JSONAnswerVocabulary(pieces: pieces, profile: profile, stopTokenIDs: stops)
    }

    static func constraint(_ format: String, phase: JSONAnswerPhase = .answer, extra: [String] = [],
                           extraBytes: [[UInt8]] = [], maxTokens: Int = 100_000) throws -> JSONAnswerConstraint {
        try JSONAnswerConstraint(format: answerFormat(format), profile: profile,
            vocabulary: vocabulary(extra: extra, extraBytes: extraBytes), initialPhase: phase, maxTokens: maxTokens)
    }

    static func walk(_ text: String, _ constraint: JSONAnswerConstraint, from initial: Int = 0) -> Int? {
        var state = initial
        for byte in text.utf8 {
            guard let next = constraint.nextState(state: state, tokenID: Int(byte)) else { return nil }
            state = next
        }
        return state
    }

    static func singleBytes(_ allowed: [Int]) -> [UInt8] { allowed.filter { $0 < 256 }.map { UInt8($0) } }
}

/// Qwen-shaped byte-level tokenizer: GPT-2 single-byte spellings at ids
/// 0...255, "x" for the other base ids, the pinned added tokens, placeholder
/// added tokens up to 248076 and nothing beyond. Its template renders a JSON
/// request's no-thinking default as the shipped templates do.
struct QwenByteTestTokenizer: MLXLMCommon.Tokenizer {
    static let pinned: [(String, Int)] = [
        ("<|endoftext|>", 248044), ("<|im_start|>", 248045), ("<|im_end|>", 248046),
        ("<tool_call>", 248058), ("</tool_call>", 248059), ("<think>", 248068), ("</think>", 248069),
    ]
    private static let byteSpelling: [UInt8: String] = {
        var spelling = [UInt8: String]()
        for value in UInt32(0)..<512 {
            let text = String(Character(Unicode.Scalar(value)!))
            if let bytes = ByteLevelBPE.bytes(text), bytes.count == 1 { spelling[bytes[0]] = text }
        }
        return spelling
    }()

    var markers = Self.pinned
    var encodesMarkers = true
    var missingBaseID: Int?

    static func tokens(_ text: String, markers: [(String, Int)] = pinned) -> [Int] {
        let bytes = Array(text.utf8)
        var ids: [Int] = []
        var index = 0
        while index < bytes.count {
            if let marker = markers.first(where: { bytes[index...].starts(with: Array($0.0.utf8)) }) {
                ids.append(marker.1)
                index += marker.0.utf8.count
            } else {
                ids.append(Int(bytes[index]))
                index += 1
            }
        }
        return ids
    }

    static func piece(_ id: Int) -> [UInt8] {
        if let marker = pinned.first(where: { $0.1 == id }) { return Array(marker.0.utf8) }
        return id < 256 ? [UInt8(id)] : Array("x".utf8)
    }

    static func prompt(thinking: Bool) -> String {
        "<|im_start|>user\nhi<|im_end|>\n<|im_start|>assistant\n<think>\n" + (thinking ? "" : "\n</think>\n\n")
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        encodesMarkers ? Self.tokens(text, markers: markers) : Array(text.utf8).map(Int.init)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        String(decoding: tokenIds.flatMap { id in
            markers.first(where: { $0.1 == id }).map { Array($0.0.utf8) } ?? Self.piece(id)
        }, as: UTF8.self)
    }
    func convertTokenToId(_ token: String) -> Int? { markers.first { $0.0 == token }?.1 }
    func convertIdToToken(_ id: Int) -> String? {
        if let marker = markers.first(where: { $0.1 == id }) { return marker.0 }
        if id < 256 { return Self.byteSpelling[UInt8(id)] }
        if id < 248044 { return id == missingBaseID ? nil : "x" }
        return id <= 248076 ? "<|extra_\(id)|>" : nil
    }
    var bosToken: String? { nil }
    var eosToken: String? { "<|im_end|>" }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?) throws -> [Int] {
        Self.tokens(Self.prompt(thinking: additionalContext?["enable_thinking"] as? Bool != false))
    }
}

@Suite("Qwen JSON answer constraint")
struct QwenJSONAnswerConstraintTests {
    private typealias F = QwenAnswerFixture

    @Test func answerPhaseAcceptsOneJSONValueThenAnAnswerEOS() throws {
        let constraint = try F.constraint(F.jsonObject)
        #expect(constraint.channelPrefix == "<think></think>")
        for text in [#"{"a":[1,true,null,"x"],"b":{}}"#, " \n{\"a\":1} \n"] {
            let state = try #require(F.walk(text, constraint), "\(text)")
            #expect(constraint.nextState(state: state, tokenID: F.imEnd) == -1)
            #expect(constraint.nextState(state: state, tokenID: F.endOfText) == -1)
            let allowed = constraint.allowedTokenIDs(state: state, remainingTokens: 10)
            #expect(allowed == [9, 10, 13, 32, F.endOfText, F.imEnd])
            for id in [F.imStart, F.toolCall, F.think, F.thinkClose, 248_100, 248_319] {
                #expect(constraint.nextState(state: state, tokenID: id) == nil, "\(id)")
            }
        }
        for text in ["Answer", "[1]", #""x""#, "1", "<think>x</think>{}", "</think>{}", #"{"a":1}x"#,
                     #"{"a":1}{"#, "{'a':1}", "```json\n{}", #"{"a":1,}"#] {
            #expect(F.walk(text, constraint) == nil, "\(text)")
        }
    }

    @Test func answerEOSIsMaskedUntilTheValueCompletes() throws {
        let constraint = try F.constraint(F.jsonObject)
        let text = #"{"a": [1, 2.5e-3, "q\"\\é"], "b": {"c": null}}"#
        let bytes = Array(text.utf8)
        for end in 0..<bytes.count {
            let state = try #require(F.walk(String(decoding: bytes[..<end], as: UTF8.self), constraint))
            let allowed = constraint.allowedTokenIDs(state: state, remainingTokens: 10)
            #expect(!allowed.contains(F.imEnd) && !allowed.contains(F.endOfText))
            #expect(constraint.nextState(state: state, tokenID: F.imEnd) == nil)
        }
        let integer = try F.constraint(F.schemaFormat(#"{"type":"integer","enum":[1,12,-3]}"#))
        for (text, stops) in [("1", true), ("12", true), ("-", false), ("-3", true)] {
            let state = try #require(F.walk(text, integer))
            #expect((integer.nextState(state: state, tokenID: F.imEnd) == -1) == stops, "\(text)")
        }
    }

    @Test func promptOpenedReasoningMasksEOSUntilTheCloseMarker() throws {
        let constraint = try F.constraint(F.jsonObject, phase: .reasoning)
        #expect(constraint.channelPrefix == "<think>")
        // Free text, JSON-looking or not, and a nested opening stay reasoning.
        let reasoning = try #require(F.walk(#"plan {{{ "unterminated <think> <tool_call> <|im_"#, constraint))
        #expect(constraint.allowedTokenIDs(state: 0, remainingTokens: 10).contains(F.think))
        for state in [0, reasoning] {
            let allowed = constraint.allowedTokenIDs(state: state, remainingTokens: 10)
            for stop in [F.imEnd, F.endOfText] {
                #expect(!allowed.contains(stop))
                #expect(constraint.nextState(state: state, tokenID: stop) == nil)
            }
        }
        // The close token or its spelling ends reasoning; one JSON value follows.
        let thought = try #require(F.walk("plan", constraint))
        for close in [[F.thinkClose], Array("</think>".utf8).map(Int.init)] {
            var state = thought
            for id in close { state = try #require(constraint.nextState(state: state, tokenID: id)) }
            let answer = try #require(F.walk("\n\n{\"a\":1}", constraint, from: state))
            #expect(constraint.nextState(state: answer, tokenID: F.imEnd) == -1)
            #expect(F.walk("Answer", constraint, from: state) == nil)
            #expect(constraint.nextState(state: state, tokenID: F.thinkClose) == nil)
        }
        // Turn and stop spellings never appear in reasoning, however split.
        for marker in ["<|im_end|>", "<|endoftext|>", "<|im_start|>"] {
            let prefix = try #require(F.walk("plan " + String(marker.dropLast()), constraint), "\(marker)")
            #expect(constraint.nextState(state: prefix, tokenID: 62) == nil)
            #expect(!constraint.allowedTokenIDs(state: prefix, remainingTokens: 10).contains(62))
        }
        // An exhausted budget ends inside reasoning, never with a fabricated stop.
        #expect(constraint.allowedTokenIDs(state: reasoning, remainingTokens: 0).isEmpty)
    }

    @Test func schemaViolationsAreMasked() throws {
        let constraint = try F.constraint(F.schemaFormat(F.schema))
        for text in [#"{"count": 3, "tables_used": ["orders", "users"], "label": "a", "note": null}"#,
                     #"{"tables_used":[],"count":-0}"#, "\n{\n  \"count\": 7,\n  \"tables_used\": [\"x\"]\n}\n"] {
            let state = try #require(F.walk(text, constraint), "\(text)")
            #expect(constraint.nextState(state: state, tokenID: F.imEnd) == -1)
        }
        // Near-miss keys, a string for an integer, prose, extra or repeated keys.
        for text in [#"{"tables":"#, #"{"tables_used":["a"],"count":"3""#, #"{"count":1.5"#, "Here is the JSON",
                     #"{"tables_used":["a"],"count":1,"extra""#, #"{"tables_used":[1"#, #"{"label":"c""#,
                     #"{"tables_used":["a","b","c","d""#, #"{"count":1,"count""#, #"{"count":1}"#] {
            #expect(F.walk(text, constraint) == nil, "\(text)")
        }
        let keyStart = try #require(F.walk(#"{""#, constraint))
        #expect(F.singleBytes(constraint.allowedTokenIDs(state: keyStart, remainingTokens: 10)) == Array("clnt".utf8))
    }

    @Test func forbiddenSpellingsAreImpossibleInTheAnswer() throws {
        let constraint = try F.constraint(F.jsonObject)
        let inString = try #require(F.walk(#"{"a":""#, constraint))
        for marker in ["<think>", "</think>", "<tool_call>", "</tool_call>", "<function=", "<|im_start|>",
                       "<|im_end|>", "<|endoftext|>"] {
            #expect(F.walk(marker, constraint, from: inString) == nil, "\(marker)")
            #expect(F.walk(String(marker.dropLast()), constraint, from: inString) != nil, "\(marker)")
            #expect(F.walk(#"{""# + marker, constraint) == nil, "key \(marker)")
        }
        #expect(F.walk(#"<b> & </p> <thin <function x= <|im_ <arg_key>"#, constraint, from: inString) != nil)
        let allowed = Set(constraint.allowedTokenIDs(state: inString, remainingTokens: 10))
        for id in [F.think, F.thinkClose, F.imStart, F.toolCall, F.imEnd] { #expect(!allowed.contains(id)) }
    }

    @Test func masksAgreeWithTransitionsAtVisitedBoundaries() throws {
        let extra = ["{\"", "\":", "\", \"", " \"", "true", "null", "12", ".5", "e-", "\n  ", "\"}", "}]", "\\n",
                     "\\u00", "\"a", "count", "tables_used\":[\"", "é", "<thi", "nk>", "</", "think>\n\n{", "|>",
                     "<|im_end", "=", "<function", "x>"]
        let cases: [(String, JSONAnswerPhase, [String])] = [
            (F.schemaFormat(F.schema), .answer, ["", " ", "{", "{\"", "{\"cou", "{\"count\"", "{\"count\":",
                "{\"count\":1", "{\"count\":1,\"tables_used\":[", "{\"count\":1,\"tables_used\":[\"a",
                "{\"count\":1,\"tables_used\":[\"a\\", "{\"count\":1,\"tables_used\":[\"a\\u0",
                "{\"count\":1,\"tables_used\":[\"<|im_end", "{\"count\":1,\"tables_used\":[\"<function",
                "{\"count\":1,\"tables_used\":[]}", "{\"count\":1,\"tables_used\":[]} ", "{\"label\":\"",
                "{\"note\":nu"]),
            (F.jsonObject, .reasoning, ["", "plan", "plan <", "plan </think", "plan <|im_end|", "plan </think>",
                "plan </think>\n{\"k\":\"<think", "plan </think>{}"]),
        ]
        let markers = [F.endOfText, F.imStart, F.imEnd, F.toolCall, F.think, F.thinkClose, 248_100, 248_319]
        for (format, phase, paths) in cases {
            let constraint = try F.constraint(format, phase: phase, extra: extra)
            let candidates = Array(0..<(256 + extra.count)) + markers
            for path in paths {
                let state = try #require(F.walk(path, constraint), "\(path)")
                let allowed = constraint.allowedTokenIDs(state: state, remainingTokens: 100)
                #expect(allowed == Array(Set(allowed)).sorted())
                #expect(Set(allowed).isSubset(of: Set(candidates)))
                for token in candidates {
                    #expect(allowed.contains(token) == (constraint.nextState(state: state, tokenID: token) != nil),
                            "\(path) token \(token)")
                }
            }
        }
    }

    @Test func outputsAreAcceptedAtEveryTokenSplit() throws {
        let cases: [(String, JSONAnswerPhase, String)] = [
            (F.schemaFormat(F.schema), .reasoning, #"plan</think>{"count":12,"tables_used":["a"]}"#),
            (F.jsonObject, .answer, " {\"age\": -0, \"name\": \"x\\\"y\\u00e9 <b>\", \"ok\": [true]}\n"),
        ]
        for (format, phase, text) in cases {
            let bytes = Array(text.utf8)
            for split in 1..<bytes.count {
                let constraint = try F.constraint(format, phase: phase,
                    extraBytes: [Array(bytes[..<split]), Array(bytes[split...])])
                let first = try #require(constraint.nextState(state: 0, tokenID: 256), "\(split)")
                let final = try #require(constraint.nextState(state: first, tokenID: 257), "\(split)")
                #expect(constraint.nextState(state: final, tokenID: F.imEnd) == -1)
            }
        }
    }

    @Test func freeTextStatesCollapseAndNestingIsBounded() throws {
        let constraint = try F.constraint(F.jsonObject)
        let inString = try #require(F.walk(#"{"a":""#, constraint))
        let before = constraint.cachedStateCount
        var state = inString
        for _ in 0..<20_000 { state = try #require(constraint.nextState(state: state, tokenID: 120)) }
        #expect(state == inString && constraint.cachedStateCount == before)
        let reasoning = try F.constraint(F.jsonObject, phase: .reasoning)
        var thought = 0
        for _ in 0..<20_000 { thought = try #require(reasoning.nextState(state: thought, tokenID: 120)) }
        #expect(thought == 0 && reasoning.cachedStateCount == 1)
        let deepest = #"{"a":"# + String(repeating: "[", count: FlintJSONState.maximumDepth - 1)
        let nested = try #require(F.walk(deepest, constraint))
        #expect(F.walk("[", constraint, from: nested) == nil)
        #expect(F.walk("1", constraint, from: nested) != nil)
    }

    @Test func statePoolExhaustionFailsClosedWithoutAnAnswerEOS() throws {
        let constraint = try F.constraint(F.jsonObject)
        let inString = try #require(F.walk(#"{"a":""#, constraint))
        let complete = try #require(F.walk(#"{"a":1}"#, constraint))
        #expect(constraint.allowedTokenIDs(state: complete, remainingTokens: 100).contains(F.imEnd))
        #expect(constraint.maskCacheKey(state: complete, remainingTokens: 100) != nil)
        #expect(constraint.nextState(state: complete, tokenID: F.imEnd) == -1)
        // Each object/array nesting path interns its own boundaries: the
        // prefixes of all 13-level paths far exceed the 8,192-state pool.
        #expect(JSONAnswerConstraint.maximumStates == 8_192)
        var exhausted = false
        for path in 0..<(1 << 13) {
            let text = #"{"a":"# + (0..<13).map { (path >> $0) & 1 == 0 ? "[" : #"{"k":"# }.joined()
            guard F.walk(text, constraint) != nil else { exhausted = true; break }
        }
        #expect(exhausted)
        #expect(constraint.cachedStateCount == JSONAnswerConstraint.maximumStates)
        // Every state, even a complete answer with a cached mask, is now
        // impossible: no mask, no reusable device mask, no answer EOS and no
        // known transition, so the sampler ends with the typed failure.
        for state in [0, inString, complete] {
            #expect(constraint.allowedTokenIDs(state: state, remainingTokens: 100).isEmpty)
            #expect(constraint.maskCacheKey(state: state, remainingTokens: 100) == nil)
            for stop in [F.imEnd, F.endOfText] { #expect(constraint.nextState(state: state, tokenID: stop) == nil) }
        }
        #expect(constraint.nextState(state: inString, tokenID: 120) == nil)
        #expect(F.walk(#"{"a":1}"#, constraint) == nil)
        #expect(constraint.cachedStateCount == JSONAnswerConstraint.maximumStates)
    }

    @Test func maskCacheKeysIdentifyBoundariesAcrossPhases() throws {
        let constraint = try F.constraint(F.schemaFormat(F.schema), phase: .reasoning)
        for (state, remaining) in [(0, 0), (-1, 10), (constraint.cachedStateCount, 10)] {
            #expect(constraint.maskCacheKey(state: state, remainingTokens: remaining) == nil)
        }
        // Each group spells one boundary several ways; the groups differ in
        // phase, marker window or JSON position.
        let items = "</think>{\"count\":1,\"tables_used\":["
        let groups: [[String]] = [
            ["", "plan", "{\"count\":1,"],
            ["plan <|im_end|", "<|im_end|"],
            ["plan</think>", "</think>\n "],
            ["plan</think>{\"count\":7", "</think>{ \"count\" : 3"],
            [items + "\"a", items + "\"abc def"],
            [items + "\"<|im_end|", items + "\"x<|im_end|"],
            [items + "]}", items + "] } \n"],
        ]
        var masksByKey: [Int: [Int]] = [:]
        var groupKeys: [Int] = []
        for group in groups {
            var keys = Set<Int>()
            for path in group {
                let state = try #require(F.walk(path, constraint), "\(path)")
                #expect(constraint.maskCacheKey(state: state, remainingTokens: 0) == nil)
                for remaining in [1, 2, 100] {
                    let key = try #require(constraint.maskCacheKey(state: state, remainingTokens: remaining), "\(path)")
                    let allowed = constraint.allowedTokenIDs(state: state, remainingTokens: remaining)
                    let known = masksByKey[key, default: allowed]
                    #expect(known == allowed, "\(path)")
                    masksByKey[key] = known
                    keys.insert(key)
                }
            }
            #expect(keys.count == 1, "\(group)")
            groupKeys.append(try #require(keys.first))
        }
        // Distinct boundaries never share a key, as the same marker prefix in
        // reasoning and in an answer string must not share a mask.
        #expect(Set(groupKeys).count == groups.count)
        #expect(masksByKey[groupKeys[1]] != masksByKey[groupKeys[5]])
        // In reverse, the recent masks are LRU hits and the rest are rebuilt;
        // both stay exact transitions.
        let candidates = Array(0...255) + [F.endOfText, F.imStart, F.imEnd, F.toolCall, F.think, F.thinkClose,
                                           256, 248_100, 248_319]
        for (group, key) in zip(groups, groupKeys).reversed() {
            let state = try #require(F.walk(group[0], constraint))
            #expect(constraint.maskCacheKey(state: state, remainingTokens: 10) == key)
            let allowed = constraint.allowedTokenIDs(state: state, remainingTokens: 10)
            #expect(allowed == masksByKey[key], "\(group[0])")
            for token in candidates {
                #expect(allowed.contains(token) == (constraint.nextState(state: state, tokenID: token) != nil),
                        "\(group[0]) token \(token)")
            }
        }
    }

    @Test func chainedSpeculationReproducesTheUnchainedStream() throws {
        let text = "plan {\"x\": </thi <|im_end| </think>\n"
            + #"{"count": 12, "tables_used": ["a b", "<|im_end|"], "note": null}"#
        let tokens = Array(text.utf8).map(Int.init) + [F.imEnd]
        let format = F.schemaFormat(F.schema)
        // Unchained: each step is masked with the state confirmed through the
        // previous token.
        let reference = try F.constraint(format, phase: .reasoning, maxTokens: tokens.count)
        var states = [reference.initialState]
        var masks: [[Int]] = []
        for (step, token) in tokens.enumerated() {
            masks.append(reference.allowedTokenIDs(state: states[step], remainingTokens: reference.maxTokens - step))
            #expect(masks[step].contains(token), "\(step)")
            states.append(try #require(reference.nextState(state: states[step], tokenID: token), "\(step)"))
        }
        #expect(states.last == -1)
        // Chained, as CBv2 drives it: while token n is pending, step n + 1 is
        // masked with the state confirmed through n - 1 and its own budget,
        // then kept if token n left that state unchanged and redrawn if not.
        let chained = try F.constraint(format, phase: .reasoning, maxTokens: tokens.count)
        #expect(chained.allowsChainedDecode)
        var state = chained.initialState
        var mask = chained.allowedTokenIDs(state: state, remainingTokens: chained.maxTokens)
        var kept = 0, redrawn = 0
        for (step, token) in tokens.enumerated() {
            #expect(mask == masks[step], "\(step)")
            let remaining = chained.maxTokens - step - 1
            let speculative = chained.allowedTokenIDs(state: state, remainingTokens: remaining)
            let confirmed = try #require(chained.nextState(state: state, tokenID: token), "\(step)")
            #expect(confirmed == states[step + 1], "\(step)")
            if remaining == 0 {
                // The successor launched past the budget is discarded: its
                // mask is empty and has no cache key.
                #expect(speculative.isEmpty && chained.maskCacheKey(state: state, remainingTokens: 0) == nil)
            } else if confirmed == state {
                kept += 1
                mask = speculative
            } else {
                redrawn += 1
                mask = chained.allowedTokenIDs(state: confirmed, remainingTokens: remaining)
            }
            state = confirmed
        }
        #expect(kept > 0 && redrawn > 0)
        // Speculation interned nothing and the zero-budget call latched nothing.
        #expect(chained.cachedStateCount == reference.cachedStateCount)
        #expect(chained.allowedTokenIDs(state: states[tokens.count - 1], remainingTokens: 1) == masks[tokens.count - 1])
        // A rebuilt row replays its confirmed tokens to the same ids, so masks
        // cached under those keys stay valid.
        var replay = chained.initialState
        for (step, token) in tokens.enumerated() {
            replay = try #require(chained.nextState(state: replay, tokenID: token), "\(step)")
            #expect(replay == states[step + 1], "\(step)")
        }
        #expect(chained.cachedStateCount == reference.cachedStateCount)
    }

    @Test func idsWithoutAPieceAreNeverAllowed() throws {
        let vocabulary = try F.vocabulary()
        #expect(vocabulary.pieceTokenIDs == Array(0...255) + [F.think, F.thinkClose])
        #expect(vocabulary.answerEOS == [F.endOfText, F.imEnd] && vocabulary.fallbackTokenID == F.imEnd)
        let constraint = try F.constraint(F.jsonObject, phase: .reasoning)
        #expect(constraint.allowedTokenIDs(state: 0, remainingTokens: 10) == vocabulary.pieceTokenIDs)
        for id in [256, 248_043, F.imStart, F.toolCall, 248_077, 248_319, 248_320, -1] {
            #expect(constraint.nextState(state: 0, tokenID: id) == nil, "\(id)")
        }
    }

    @Test func theTokenizerMustMatchThePinnedContract() throws {
        let vocabulary = try JSONAnswerVocabulary(tokenizer: QwenByteTestTokenizer(), profile: .qwen35,
            stopTokenIDs: F.stops)
        #expect(vocabulary.pieces.count == 248_320 && vocabulary.pieces[32] == [32])
        #expect(vocabulary.pieces[1000] == Array("x".utf8) && vocabulary.pieces[F.think] == Array("<think>".utf8))
        for id in [F.endOfText, F.imStart, F.imEnd, F.toolCall, 248_070, 248_076, 248_100] {
            #expect(vocabulary.pieces[id].isEmpty, "\(id)")
        }
        let moved = QwenByteTestTokenizer.pinned.map { $0.0 == "<think>" ? ($0.0, 248_070) : $0 }
        for broken in [QwenByteTestTokenizer(markers: moved), QwenByteTestTokenizer(encodesMarkers: false),
                       QwenByteTestTokenizer(missingBaseID: 5000)] {
            #expect(throws: ToolConstraintSchemaError.self) {
                try JSONAnswerVocabulary(tokenizer: broken, profile: .qwen35, stopTokenIDs: F.stops)
            }
        }
        // Both answer terminators must be engine stop tokens.
        #expect(throws: ToolConstraintSchemaError.self) {
            try JSONAnswerVocabulary(tokenizer: QwenByteTestTokenizer(), profile: .qwen35, stopTokenIDs: [F.imEnd])
        }
    }
}
