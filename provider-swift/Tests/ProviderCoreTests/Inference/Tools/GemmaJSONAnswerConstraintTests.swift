import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

/// Gemma 4-shaped SentencePiece tokenizer: the 24 added tokens at their real
/// ids, `\n` and `\n\n` at 107/108, the 256 byte-fallback tokens at 238...493,
/// one piece per printable ASCII character at 1000 + byte (the space spelled
/// `▁`), a few multi-character pieces from 2000, and `<unusedN>` everywhere
/// else up to the model's 262,144 ids. Decoding follows the shipped decoder:
/// U+2581 to a space, byte-fallback runs fused as UTF-8 (one U+FFFD per byte
/// when a run is not UTF-8), no strip.
struct GemmaPieceTestTokenizer: MLXLMCommon.Tokenizer {
    static let vocabularySize = 262_144
    static let specials: [Int: String] = [
        0: "<pad>", 1: "<eos>", 2: "<bos>", 3: "<unk>", 4: "<mask>", 46: "<|tool>", 47: "<tool|>",
        48: "<|tool_call>", 49: "<tool_call|>", 50: "<|tool_response>", 51: "<tool_response|>", 52: "<|\"|>",
        98: "<|think|>", 100: "<|channel>", 101: "<channel|>", 105: "<|turn>", 106: "<turn|>",
        255_999: "<|image>", 256_000: "<|audio>", 258_880: "<|image|>", 258_881: "<|audio|>",
        258_882: "<image|>", 258_883: "<audio|>", 258_884: "<|video|>",
    ]
    static let extras = [
        "▁{", "{\"", "\":", "\",", "▁\"", "\"}", "}}", "▁hello", "▁▁", "é", "<b>", "```", "```json", "json",
        "|>{", "channel", "turn", "thought", "▁world", "▁▁▁▁", "\n▁▁",
    ]

    var specials = Self.specials
    var size = Self.vocabularySize

    static func id(_ piece: String) -> Int {
        if let index = extras.firstIndex(of: piece) { return 2000 + index }
        if piece == "\n" { return 107 }
        if piece == "\n\n" { return 108 }
        if piece == " " || piece == "▁" { return 1032 }
        if let special = specials.first(where: { $0.value == piece }) { return special.key }
        precondition(piece.utf8.count == 1, "no single piece for \(piece)")
        return 1000 + Int(piece.utf8.first!)
    }

    static func byteFallback(_ byte: UInt8) -> Int { 238 + Int(byte) }

    func convertIdToToken(_ id: Int) -> String? {
        guard (0..<size).contains(id) else { return nil }
        if let special = specials[id] { return special }
        if id == 107 { return "\n" }
        if id == 108 { return "\n\n" }
        if (238...493).contains(id) { return String(format: "<0x%02X>", id - 238) }
        if (1032...1126).contains(id) { return id == 1032 ? "▁" : String(UnicodeScalar(UInt8(id - 1000))) }
        if (2000..<(2000 + Self.extras.count)).contains(id) { return Self.extras[id - 2000] }
        return "<unused\(id)>"
    }

    func convertTokenToId(_ token: String) -> Int? { specials.first { $0.value == token }?.key }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        var ids: [Int] = []
        var rest = Substring(text)
        while let first = rest.first {
            if let special = specials.filter({ rest.hasPrefix($0.value) }).max(by: { $0.value.count < $1.value.count }) {
                ids.append(special.key)
                rest = rest.dropFirst(special.value.count)
                continue
            }
            rest = rest.dropFirst()
            if first == "\n" { ids.append(107) }
            else if first == " " { ids.append(1032) }
            else if let ascii = first.asciiValue, (0x21...0x7E).contains(ascii) { ids.append(1000 + Int(ascii)) }
            else { ids += String(first).utf8.map(Self.byteFallback) }
        }
        return ids
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        var text = ""
        var run: [UInt8] = []
        func flush() {
            guard !run.isEmpty else { return }
            text += String(bytes: run, encoding: .utf8) ?? String(repeating: "\u{FFFD}", count: run.count)
            run = []
        }
        for id in tokenIds {
            guard let raw = convertIdToToken(id) else { continue }
            if (238...493).contains(id) {
                run.append(UInt8(id - 238))
                continue
            }
            flush()
            if specials[id] != nil, skipSpecialTokens { continue }
            text += raw.replacingOccurrences(of: "▁", with: " ")
        }
        flush()
        return text
    }

    static func prompt(thinking: Bool) -> String {
        "<bos><|turn>user\nhi<turn|>\n<|turn>model\n" + (thinking ? "" : "<|channel>thought\n<channel|>")
    }

    var bosToken: String? { "<bos>" }
    var eosToken: String? { "<turn|>" }
    var unknownToken: String? { "<unk>" }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        encode(text: Self.prompt(thinking: additionalContext?["enable_thinking"] as? Bool == true),
               addSpecialTokens: false)
    }
}

enum GemmaAnswerFixture {
    static let stops: Set<Int> = [1, 50, 106]
    static let eos = 1, turnEnd = 106, toolResponse = 50, thoughtOpen = 100, thoughtClose = 101
    static let tokenizer = GemmaPieceTestTokenizer()
    private static let shared = Result { try GemmaAnswerPieces.vocabulary(tokenizer: tokenizer, stopTokenIDs: stops) }

    static let schema = #"""
    {"type":"object","properties":{
      "name":{"type":"string"},
      "kind":{"type":"string","enum":["cat","dog"]},
      "size":{"type":"integer","enum":[1,12]},
      "tags":{"type":"array","items":{"type":"string"},"maxItems":2},
      "owner":{"type":"object","properties":{"id":{"type":"integer"}},"required":["id"],
               "additionalProperties":false}},
     "required":["name","owner"],"additionalProperties":false}
    """#
    static let jsonObject = #"{"type":"json_object"}"#

    static func schemaFormat(_ schema: String) -> String {
        #"{"type":"json_schema","json_schema":{"name":"out","schema":"# + schema + "}}"
    }

    static func vocabulary() throws -> JSONAnswerVocabulary { try shared.get() }

    static func answerFormat(_ format: String) throws -> JSONAnswerFormat {
        let body = #"{"model":"gemma","messages":[{"role":"user","content":"hi"}],"response_format":"# + format + "}"
        let request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: Data(body.utf8))
        return try #require(GemmaJSONAnswerPolicy.answerFormat(try #require(request.responseFormat)))
    }

    static func constraint(_ format: String = jsonObject, phase: GemmaJSONAnswerBoundary.Phase = .answer,
                           maxTokens: Int = 100_000,
                           maximumStates: Int = GemmaJSONAnswerConstraint.defaultMaximumStates) throws
        -> GemmaJSONAnswerConstraint {
        try GemmaJSONAnswerConstraint(format: answerFormat(format), vocabulary: vocabulary(), initialPhase: phase,
            maxTokens: maxTokens, maximumStates: maximumStates)
    }

    /// Ids for `text`: one piece per character, byte fallback for the rest.
    static func ids(_ text: String) -> [Int] { tokenizer.encode(text: text, addSpecialTokens: false) }

    static func pieces(_ pieces: String...) -> [Int] { pieces.map(GemmaPieceTestTokenizer.id) }

    /// Walks `tokens`, checking that the mask admits each one before it is
    /// taken: the transition and the mask must agree.
    static func walk(_ tokens: [Int], _ constraint: GemmaJSONAnswerConstraint, from initial: Int = 0) -> Int? {
        var state = initial
        for token in tokens {
            guard constraint.allowedTokenIDs(state: state, remainingTokens: 1_000).contains(token),
                  let next = constraint.nextState(state: state, tokenID: token) else { return nil }
            state = next
        }
        return state
    }

    static func allows(_ constraint: GemmaJSONAnswerConstraint, _ state: Int, _ token: Int) -> Bool {
        constraint.allowedTokenIDs(state: state, remainingTokens: 1_000).contains(token)
    }
}

@Suite("Gemma JSON answer pieces")
struct GemmaAnswerPiecesTests {
    private typealias F = GemmaAnswerFixture

    @Test func piecesDecodeToTheBytesTheStreamShows() {
        let cases: [(String, String?)] = [
            ("▁hello", " hello"), ("▁▁", "  "), ("hello▁world", "hello world"), ("\n", "\n"), ("é", "é"),
            ("<b>", "<b>"), ("</table>", "</table>"), ("<unusedx>", "<unusedx>"), ("<0x4G>", "<0x4G>"),
            ("<unused7>", nil), ("<unused262143>", nil), ("<channel|>", nil), ("<turn|>", nil), ("<eos>", nil),
            ("<|\"|>", nil), ("<0x22>", nil), ("<0x0A>", nil), ("<0x7F>", nil), ("", nil),
        ]
        for (raw, text) in cases {
            #expect(GemmaAnswerPieces.bytes(raw) == text.map { Array($0.utf8) }, "\(raw)")
        }
        // Non-ASCII byte fallback is one raw byte; it joins a run the decoder fuses.
        #expect(GemmaAnswerPieces.bytes("<0xC3>") == [0xC3] && GemmaAnswerPieces.bytes("<0xa9>") == [0xA9])
    }

    @Test func theVocabularyHoldsTheAnswerPiecesOnly() throws {
        let vocabulary = try F.vocabulary()
        #expect(vocabulary.pieces.count == 262_144)
        #expect(vocabulary.pieces[100] == Array("<|channel>".utf8) && vocabulary.pieces[101] == Array("<channel|>".utf8))
        let usable = Set(vocabulary.pieceTokenIDs)
        for id in [0, 1, 2, 48, 50, 52, 98, 105, 106, 6, 99, 5_000, 262_143] { #expect(!usable.contains(id), "\(id)") }
        for byte in 0..<0x80 { #expect(!usable.contains(GemmaPieceTestTokenizer.byteFallback(UInt8(byte)))) }
        for byte in 0x80...0xFF { #expect(usable.contains(GemmaPieceTestTokenizer.byteFallback(UInt8(byte)))) }
        #expect(vocabulary.pieces[1032] == [0x20] && vocabulary.pieces[107] == [0x0A])
        #expect(vocabulary.answerEOS == [1, 106] && vocabulary.fallbackTokenID == 106)
    }

    @Test func theVocabularyRequiresThePinnedContract() throws {
        var moved = GemmaPieceTestTokenizer()
        moved.specials[101] = nil
        moved.specials[102] = "<channel|>"
        var larger = GemmaPieceTestTokenizer()
        larger.size = 262_145
        var smaller = GemmaPieceTestTokenizer()
        smaller.size = 262_000
        for tokenizer in [moved, larger, smaller] {
            #expect(throws: ToolConstraintSchemaError.self) {
                try GemmaAnswerPieces.vocabulary(tokenizer: tokenizer, stopTokenIDs: F.stops)
            }
        }
        // Every answer terminator must also stop the engine.
        #expect(throws: ToolConstraintSchemaError.self) {
            try GemmaAnswerPieces.vocabulary(tokenizer: GemmaPieceTestTokenizer(), stopTokenIDs: [1, 50])
        }
    }
}

@Suite("Gemma JSON answer constraint")
struct GemmaJSONAnswerConstraintTests {
    private typealias F = GemmaAnswerFixture

    @Test func oneObjectWalksWhateverTheTokenBoundaries() throws {
        let text = #"{"a": [1, -2.5e3, "x\u00e9", true], "b": {"c": null}}"#
        let tokenizations: [[Int]] = [
            F.ids(text),
            F.pieces("{\"") + F.ids(#"a"#) + F.pieces("\":") + F.ids(#" [1, -2.5e3,"#) + F.pieces("▁\"")
                + F.ids(#"x\u00e9"#) + F.pieces("\",") + F.ids(#" true], "b": {"c": null"#) + F.pieces("}}"),
        ]
        for tokens in tokenizations {
            let constraint = try F.constraint()
            let end = try #require(F.walk(tokens, constraint))
            for eos in [F.turnEnd, F.eos] { #expect(constraint.nextState(state: end, tokenID: eos) == -1) }
            // After the closing brace only the terminators remain: no blank line, no fence.
            #expect(constraint.allowedTokenIDs(state: end, remainingTokens: 10) == [F.eos, F.turnEnd])
            #expect(constraint.nextState(state: end, tokenID: F.toolResponse) == nil)
            // Before the value is complete no terminator is admitted.
            let open = try #require(F.walk(Array(tokens.dropLast()), constraint))
            #expect(!F.allows(constraint, open, F.turnEnd) && constraint.nextState(state: open, tokenID: F.turnEnd) == nil)
        }
    }

    @Test func nonASCIIBytesStayInsideStrings() throws {
        let constraint = try F.constraint()
        let string = try #require(F.walk(F.ids(#"{"k": ""#), constraint))
        let lead = GemmaPieceTestTokenizer.byteFallback(0xC3), trail = GemmaPieceTestTokenizer.byteFallback(0xA9)
        let accented = try #require(F.walk([lead, trail], constraint, from: string))
        #expect(try #require(F.walk(F.pieces("é") + F.ids(#""}"#), constraint, from: accented)) >= 0)
        // Outside a string a non-ASCII byte is never JSON.
        let structural = try #require(F.walk(F.ids(#"{"k": "v""#), constraint))
        #expect(!F.allows(constraint, structural, lead))
        // ASCII byte-fallback tokens are never admitted, so a run the decoder
        // fuses can never hide a quote.
        let asciiFallback = (0..<0x80).map { GemmaPieceTestTokenizer.byteFallback(UInt8($0)) }
        for state in [0, string, accented, structural] {
            let allowed = Set(constraint.allowedTokenIDs(state: state, remainingTokens: 10))
            #expect(allowed.isDisjoint(with: asciiFallback))
        }
    }

    @Test func fencesAndProseAreRefusedAndWhitespaceIsBounded() throws {
        let constraint = try F.constraint()
        for refused in F.pieces("```", "```json", "`", "json", "<b>") + F.ids("A") {
            #expect(!F.allows(constraint, 0, refused), "\(refused)")
        }
        for admitted in F.pieces("{", "▁{", "{\"", "\n", "\n\n", "▁▁▁▁") { #expect(F.allows(constraint, 0, admitted)) }
        // A model reaching for a fence cannot fill its budget with blank lines.
        var state = 0
        for _ in 0..<32 { state = try #require(constraint.nextState(state: state, tokenID: 108)) }
        #expect(!F.allows(constraint, state, 107) && !F.allows(constraint, state, 1032))
        #expect(F.allows(constraint, state, GemmaPieceTestTokenizer.id("{")))
        // Indentation inside the value is a fresh run after every token.
        let indented = try #require(F.walk(F.ids("{") + F.pieces("\n▁▁") + F.ids(#""a": 1"#)
            + F.pieces("\n▁▁") + F.ids("}"), try F.constraint()))
        #expect(indented > 0)
    }

    @Test func aThoughtStaysFreeThenTheAnswerIsJSON() throws {
        let constraint = try F.constraint(phase: .opening)
        #expect(F.allows(constraint, 0, F.thoughtOpen) && F.allows(constraint, 0, GemmaPieceTestTokenizer.id("{")))
        #expect(!F.allows(constraint, 0, F.thoughtClose) && !F.allows(constraint, 0, F.turnEnd))
        let thought = try #require(F.walk([F.thoughtOpen] + F.pieces("thought", "\n") + F.ids(#"say {"x": } "#)
            + F.pieces("```json", "<b>"), constraint))
        // The thought never ends the turn and may not open a tool call.
        for refused in [F.turnEnd, F.eos, F.toolResponse, 48, 105] { #expect(!F.allows(constraint, thought, refused)) }
        let answer = try #require(F.walk([F.thoughtClose], constraint, from: thought))
        #expect(!F.allows(constraint, answer, GemmaPieceTestTokenizer.id("s")))
        let end = try #require(F.walk(F.ids(#"{"x": 1}"#), constraint, from: answer))
        #expect(constraint.nextState(state: end, tokenID: F.turnEnd) == -1)

        // The answer can also start at once, with no thought.
        let direct = try F.constraint(phase: .opening)
        #expect(try #require(F.walk(F.ids(#" {"x": 1}"#), direct)) > 0)
    }

    @Test func theCloseMarkerCountsHoweverItIsSpelled() throws {
        // The stream's parser reads text, so a close spelled by pieces ends the thought too.
        let constraint = try F.constraint(phase: .opening)
        let thought = try #require(F.walk([F.thoughtOpen] + F.ids("hm "), constraint))
        let spelled = try #require(F.walk(F.ids("<") + F.pieces("channel") + F.ids("|>"), constraint, from: thought))
        #expect(!F.allows(constraint, spelled, GemmaPieceTestTokenizer.id("s")))
        #expect(try #require(F.walk(F.ids(#"{}"#), constraint, from: spelled)) > 0)
        // One piece may close the thought and open the value.
        let fused = try #require(F.walk(F.ids("<") + F.pieces("channel", "|>{") + F.ids("}"), constraint, from: thought))
        #expect(constraint.nextState(state: fused, tokenID: F.turnEnd) == -1)
        // Inside the thought an open marker is just text.
        #expect(F.walk([F.thoughtOpen], constraint, from: thought) != nil)
    }

    @Test func theAnswerNeverSpellsAControlMarker() throws {
        let constraint = try F.constraint()
        let string = try #require(F.walk(F.ids(#"{"k": "a"#), constraint))
        for marker in [F.thoughtOpen, F.thoughtClose] { #expect(!F.allows(constraint, string, marker)) }
        let almost = try #require(F.walk(F.ids("<") + F.pieces("turn") + F.ids("|"), constraint, from: string))
        #expect(!F.allows(constraint, almost, GemmaPieceTestTokenizer.id(">")))
        #expect(try #require(F.walk(F.ids(#" >"}"#), constraint, from: almost)) > 0)
        #expect(F.walk(F.ids("<b>"), constraint, from: string) != nil, "other markup is text")
    }

    @Test func schemasHoldKeysEnumsNestingAndCounts() throws {
        let format = F.schemaFormat(F.schema)
        let valid = #"{"tags": ["a", "b"], "owner": {"id": 7}, "kind": "dog", "size": 12, "name": "Rex"}"#
        let constraint = try F.constraint(format)
        let end = try #require(F.walk(F.ids(valid), constraint))
        #expect(constraint.nextState(state: end, tokenID: F.turnEnd) == -1)

        let refusals: [(String, String)] = [
            (#"{"nam"#, "x"), (#"{"#, "\u{27}"), (#"{"kind": "#, "c"), (#"{"kind": "c"#, "o"),
            (#"{"size": 1"#, "1"), (#"{"size": 1"#, "."), (#"{"tags": ["a", "b""#, ","),
            (#"{"owner": {"id": 1"#, ","), (#"{"name": "n""#, "}"), (#"{"owner": {"#, "}"),
        ]
        for (prefix, next) in refusals {
            let c = try F.constraint(format)
            let state = try #require(F.walk(F.ids(prefix), c), "\(prefix)")
            #expect(!F.allows(c, state, GemmaPieceTestTokenizer.id(next)), "\(prefix) then \(next)")
        }
        // A key appears at most once.
        let c = try F.constraint(format)
        let once = try #require(F.walk(F.ids(#"{"name": "a", "#), c))
        #expect(F.walk(F.ids(#""name""#), c, from: once) == nil)
    }

    @Test func rootScalarsEndWhenComplete() throws {
        let integer = try F.constraint(F.schemaFormat(#"{"type":"integer"}"#))
        let digits = try #require(F.walk(F.ids("12"), integer))
        #expect(F.allows(integer, digits, GemmaPieceTestTokenizer.id("3")) && F.allows(integer, digits, F.turnEnd))
        let string = try F.constraint(F.schemaFormat(#"{"type":"string"}"#))
        let closed = try #require(F.walk(F.ids(#""ok""#), string))
        #expect(string.allowedTokenIDs(state: closed, remainingTokens: 5) == [F.eos, F.turnEnd])
    }

    @Test func theMaskIgnoresTheBudgetAndQueriesChangeNothing() throws {
        let constraint = try F.constraint(phase: .opening)
        let thought = try #require(F.walk([F.thoughtOpen], constraint))
        let count = constraint.cachedStateCount
        for state in [0, thought] {
            #expect(constraint.allowedTokenIDs(state: state, remainingTokens: 1)
                == constraint.allowedTokenIDs(state: state, remainingTokens: 500))
            #expect(constraint.maskCacheKey(state: state, remainingTokens: 3) == state)
            #expect(constraint.allowedTokenIDs(state: state, remainingTokens: 0).isEmpty)
            #expect(constraint.maskCacheKey(state: state, remainingTokens: 0) == nil)
        }
        #expect(constraint.cachedStateCount == count && constraint.allowsChainedDecode)
        #expect(constraint.allowedTokenIDs(state: 99_999, remainingTokens: 5).isEmpty)
        #expect(constraint.nextState(state: 0, tokenID: 262_144) == nil)
    }

    @Test func pastTheStateCapTheAnswerContinuesUnconstrained() throws {
        let constraint = try F.constraint(maximumStates: 4)
        let free = try #require(F.walk(F.ids(#"{"a"#), constraint))
        #expect(constraint.cachedStateCount <= 4)
        let allowed = constraint.allowedTokenIDs(state: free, remainingTokens: 5)
        #expect(allowed.count == 262_144)
        // Unconstrained means today's behavior: any token, any stop, never an impossible state.
        #expect(constraint.nextState(state: free, tokenID: GemmaPieceTestTokenizer.id("`")) == free)
        #expect(constraint.nextState(state: free, tokenID: F.toolResponse) == -1)
    }
}
