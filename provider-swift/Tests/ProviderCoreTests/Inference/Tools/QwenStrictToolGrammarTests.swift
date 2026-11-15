import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

/// Requests as the provider sees them: the body's tools are kept as declared
/// (`Prepared.declaredTools`, what `strict` calls are validated against) and
/// rendered after ingress normalization (what the template and parser read).
enum StrictToolFixture {
    static let model = "EigenLabs/Qwen3.8-27B-4bit-mtp"
    static let stops: Set<Int> = [248044, 248046]
    static let imEnd = 248046, toolCall = 248058, toolCallClose = 248059, think = 248068, thinkClose = 248069
    /// One handle, so its vocabulary is built once for the suites.
    static let handle = TokenizerHandle(QwenByteTestTokenizer())
    static let qwenTypes = QwenStrictToolGrammar.Setting.models(["qwen3_5", "qwen3_5_moe"])

    static let order = #"""
    [{"type":"function","function":{"name":"place_order","strict":true,"parameters":{"type":"object",
      "properties":{
        "customer":{"type":"object","properties":{"name":{"type":"string"},"zip":{"type":"integer"}},
                    "required":["name","zip"],"additionalProperties":false},
        "items":{"type":"array","items":{"type":"object","properties":{"sku":{"type":"string"},
                 "qty":{"type":"integer"}},"required":["sku","qty"],"additionalProperties":false}},
        "unit":{"type":"string","enum":["celsius","fahrenheit"]},
        "count":{"type":"integer"},
        "code":{"type":"string"},
        "express":{"type":"boolean"},
        "weight":{"type":"number"},
        "note":{"type":["string","null"]}},
      "required":["customer","items","unit","count","code"],"additionalProperties":false}}},
     {"type":"function","function":{"name":"get_time","strict":true,"parameters":{"type":"object",
      "properties":{"city":{"type":"string"}},"required":["city"],"additionalProperties":false}}}]
    """#

    /// Local `$ref`/`$defs`, nested and in array items.
    static let refs = #"""
    [{"type":"function","function":{"name":"book","strict":true,"parameters":{"type":"object",
      "$defs":{"Passenger":{"type":"object","properties":{"name":{"type":"string"},"age":{"$ref":"#/$defs/Age"}},
               "required":["name","age"],"additionalProperties":false},
               "Age":{"type":"integer","description":"years"}},
      "properties":{"passengers":{"type":"array","items":{"$ref":"#/$defs/Passenger"}},
                    "lead":{"type":"object","properties":{"who":{"$ref":"#/$defs/Passenger"}},
                            "required":["who"],"additionalProperties":false}},
      "required":["passengers","lead"],"additionalProperties":false}}}]
    """#

    /// `anyOf` with null, and a reference beside an open object (tau2's shape), also as the coordinator forwards
    /// it inlined, with the render repair's `type` and empty `properties` beside the union.
    static let unions = #"""
    [{"type":"function","function":{"name":"f","strict":true,"parameters":{"type":"object",
      "$defs":{"Flight":{"type":"object","properties":{"number":{"type":"string"}},"required":["number"]}},
      "properties":{
        "limit":{"anyOf":[{"type":"integer"},{"type":"null"}]},
        "label":{"anyOf":[{"type":"string"},{"type":"null"}],"default":null},
        "flight":{"type":"object","properties":{"leg":{"anyOf":[{"$ref":"#/$defs/Flight"},
                  {"type":"object","additionalProperties":true}]}}},
        "legs":{"type":"array","items":{"anyOf":[{"type":"object","title":"FlightInfo",
                  "properties":{"number":{"type":"string"},"seats":{"type":"integer"}},"required":["number"]},
                  {"additionalProperties":true,"properties":{},"type":"object"}],"properties":{},"type":"object"}}},
      "required":["limit","label","flight"],"additionalProperties":false}}}]
    """#

    static let validOrder = """
        <tool_call>
        <function=place_order>
        <parameter=customer>
        {"name": "Ada", "zip": 94110}
        </parameter>
        <parameter=items>
        [{"sku": "A-1", "qty": 2}, {"sku": "B-2", "qty": 1}]
        </parameter>
        <parameter=unit>
        celsius
        </parameter>
        <parameter=count>
        3
        </parameter>
        <parameter=code>
        007 "quoted" <b>bold</b>
        </parameter>
        </function>
        </tool_call>
        """

    static func body(tools: String, choice: String? = nil, parallel: Bool? = nil, maxTokens: Int = 512,
                     model: String = model) -> String {
        var body = #"{"model":"\#(model)","messages":[{"role":"user","content":"hi"}],"max_tokens":\#(maxTokens)"#
            + #","tools":"# + tools
        if let choice { body += #","tool_choice":"# + choice }
        if let parallel { body += #","parallel_tool_calls":\#(parallel)"# }
        return body + "}"
    }

    /// The request after ingress normalization and its prepared policy, with
    /// the body's own declarations retained, as the scheduler prepares them.
    static func prepared(_ body: String, modelType: String = "qwen3_5") throws
        -> (OpenAIChatCompletionRequest, ToolChoicePromptPolicy.Prepared) {
        let raw = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: Data(body.utf8))
        let request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self,
            from: ToolSchemaNormalization.ensureParameterTypes(in: Data(body.utf8)))
        var prepared = try ToolChoicePromptPolicy.prepare(request, modelType: modelType)
        prepared.declaredTools = raw.tools
        return (request, prepared)
    }

    static func constraint(_ body: String, thinking: Bool = false, modelType: String = "qwen3_5",
                           runsTokenConstraints: Bool = true,
                           setting: QwenStrictToolGrammar.Setting = qwenTypes,
                           allTools: Bool = false) throws -> QwenStrictToolConstraint? {
        let (request, prepared) = try prepared(body, modelType: modelType)
        return QwenStrictToolGrammar.constraint(prepared: prepared, request: request, parser: .qwen35,
            tokenizer: handle, modelType: modelType, defaultMaxTokens: 512, stopTokenIDs: stops,
            promptTokens: QwenByteTestTokenizer.tokens(QwenByteTestTokenizer.prompt(thinking: thinking)),
            runsTokenConstraints: runsTokenConstraints, setting: setting, allTools: allTools)
    }

    /// Walks `text` token by token (markers as their added tokens, other bytes
    /// as byte pieces); nil at the first token the masks refuse.
    static func walk(_ text: String, _ constraint: QwenStrictToolConstraint, from state: Int? = nil) -> Int? {
        var state = state ?? constraint.initialState
        for token in QwenByteTestTokenizer.tokens(text) {
            guard constraint.allowedTokenIDs(state: state, remainingTokens: 1_000).contains(token),
                  let next = constraint.nextState(state: state, tokenID: token) else { return nil }
            state = next
        }
        return state
    }

    static func allows(_ text: String, _ constraint: QwenStrictToolConstraint, after prefix: String) -> Bool {
        guard let state = walk(prefix, constraint) else { return false }
        return walk(text, constraint, from: state) != nil
    }

    /// Calls the production parser reads from `content`, and their check.
    static func calls(_ content: String, _ request: OpenAIChatCompletionRequest,
                      _ prepared: ToolChoicePromptPolicy.Prepared) throws -> [ToolCall] {
        let handler = try #require(try ToolStreamPreparation.makeHandler(
            request: request, prepared: prepared, modelType: "qwen3_5", streamToolCalls: false))
        _ = handler.processChunk(content)
        let calls = handler.finish()
        try ToolConstraintValidation.validate(calls, prepared: prepared)
        return calls
    }

    /// Calls the streamed path completes from `content` (OpenAI fragments fed
    /// in chunks), and their check; a streamed call that disagrees with its
    /// parse throws.
    static func streamedCalls(_ content: String, _ body: String, chunking: Int = 7) throws -> [ToolCall] {
        var (request, prepared) = try prepared(body)
        request.streamToolCallDeltas = true
        let declared = prepared.declaredTools
        prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "qwen3_5")
        prepared.declaredTools = declared
        let handler = try #require(try ToolStreamPreparation.makeHandler(
            request: request, prepared: prepared, modelType: "qwen3_5", streamToolCalls: true))
        var router = NativeToolStreamRouter(handler: handler, requiresToolCall: false, nativePrefix: nil,
            streamedCalls: prepared)
        let characters = Array(content)
        for start in stride(from: 0, to: characters.count, by: chunking) {
            _ = try router.process(String(characters[start..<min(start + chunking, characters.count)]))
        }
        _ = try router.finishText()
        _ = try router.finishToolCalls(truncated: false)
        try ToolConstraintValidation.validate(router.completedToolCalls, prepared: prepared)
        return router.completedToolCalls
    }

    static func arguments(_ call: ToolCall) -> [String: MLXLMCommon.JSONValue] { call.function.arguments }
}

@Suite("Strict tool grammar: Qwen 3.5-family call arguments")
struct QwenStrictToolGrammarTests {
    private typealias F = StrictToolFixture

    // MARK: - The grammar

    @Test func aValidCallWalksThroughAndParsesToSchemaValidArguments() throws {
        let body = F.body(tools: F.order)
        let constraint = try #require(try F.constraint(body))
        let end = try #require(F.walk(F.validOrder, constraint))
        // The call closed: the answer may end, as without a grammar.
        #expect(constraint.nextState(state: end, tokenID: F.imEnd) == -1)
        let (request, prepared) = try F.prepared(body)
        let calls = try F.calls(F.validOrder, request, prepared)
        let arguments = try #require(calls.first.map(F.arguments))
        #expect(calls.count == 1 && calls[0].function.name == "place_order")
        #expect(arguments["customer"] == .object(["name": .string("Ada"), "zip": .int(94110)]))
        #expect(arguments["count"] == .int(3) && arguments["unit"] == .string("celsius"))
        #expect(arguments["code"] == .string(#"007 "quoted" <b>bold</b>"#), "free text stays text, unescaped")
    }

    @Test func integersAndStringsKeepTheirDeclaredJSONTypes() throws {
        let constraint = try #require(try F.constraint(F.body(tools: F.order)))
        let call = "<tool_call>\n<function=place_order>\n"
        // An integer parameter is a JSON integer: never a quoted string, a word or a fraction.
        let count = call + "<parameter=count>\n"
        #expect(F.allows("42\n</parameter>\n", constraint, after: count))
        #expect(F.allows("-7\n</parameter>\n", constraint, after: count))
        for wrong in ["\"42\"", "forty", "4.5", "1e3", "null", "", " "] {
            #expect(!F.allows(wrong + "\n</parameter>", constraint, after: count), "\(wrong)")
        }
        // A string parameter is the text itself: digits stay a string.
        #expect(F.allows("42\n</parameter>\n", constraint, after: call + "<parameter=code>\n"))
        // Nested integers inside an object.
        let customer = call + "<parameter=customer>\n{\"name\": \"Ada\", \"zip\": "
        #expect(F.allows("94110}\n</parameter>\n", constraint, after: customer))
        #expect(!F.allows("\"94110\"", constraint, after: customer))
        // Booleans and numbers.
        #expect(F.allows("true\n</parameter>\n", constraint, after: call + "<parameter=express>\n"))
        #expect(!F.allows("yes", constraint, after: call + "<parameter=express>\n"))
        #expect(F.allows("2.5\n</parameter>\n", constraint, after: call + "<parameter=weight>\n"))
    }

    @Test func enumsAdmitOnlyTheirValues() throws {
        let constraint = try #require(try F.constraint(F.body(tools: F.order)))
        let unit = "<tool_call>\n<function=place_order>\n<parameter=unit>\n"
        #expect(F.allows("celsius\n</parameter>\n", constraint, after: unit))
        #expect(F.allows("fahrenheit\n</parameter>\n", constraint, after: unit))
        for wrong in ["kelvin", "Celsius", "\"celsius\"", "celsius!", "cel\n"] {
            #expect(!F.allows(wrong + "\n</parameter>\n", constraint, after: unit), "\(wrong)")
        }
    }

    @Test func nestedObjectsAndArraysFollowTheirSchemas() throws {
        let constraint = try #require(try F.constraint(F.body(tools: F.order)))
        let items = "<tool_call>\n<function=place_order>\n<parameter=items>\n"
        #expect(F.allows("[]\n</parameter>\n", constraint, after: items))
        #expect(F.allows("[{\"qty\": 1, \"sku\": \"x\"}]\n</parameter>\n", constraint, after: items))
        // Missing a required nested key, an undeclared one, a duplicate, the wrong container.
        #expect(!F.allows("[{\"sku\": \"x\"}]", constraint, after: items))
        #expect(!F.allows("[{\"sku\": \"x\", \"qty\": 1, \"color\"", constraint, after: items))
        #expect(!F.allows("[{\"sku\": \"x\", \"sku\"", constraint, after: items))
        #expect(!F.allows("{\"sku\"", constraint, after: items))
        // A value never spells the tag that would end it early, nor a turn marker.
        #expect(!F.allows("[{\"sku\": \"a</parameter>", constraint, after: items))
        #expect(!F.allows("[{\"sku\": \"a<|im_end|>", constraint, after: items))
        // JSONSerialization refuses a lone surrogate escape (the value would stay a
        // string), so none is written; other escapes and characters as such are.
        for escape in ["\\ud83d", "\\uDFFF", "\\udBff"] {
            #expect(!F.allows("[{\"sku\": \"a" + escape, constraint, after: items), "\(escape)")
        }
        #expect(F.allows("[{\"sku\": \"\\u00e9 \u{1F600}\", \"qty\": 1}]\n</parameter>\n", constraint, after: items))
    }

    @Test func requiredOptionalUndeclaredAndDuplicateParameters() throws {
        let constraint = try #require(try F.constraint(F.body(tools: F.order)))
        let call = "<tool_call>\n<function=get_time>\n"
        // `city` is required: the function cannot close before it.
        #expect(!F.allows("</function>", constraint, after: call))
        let city = call + "<parameter=city>\nParis\n</parameter>\n"
        #expect(F.allows("</function>\n</tool_call>", constraint, after: city))
        // Each parameter at most once; undeclared ones never.
        #expect(!F.allows("<parameter=city>", constraint, after: city))
        #expect(!F.allows("<parameter=country>", constraint, after: call))
        // Optional parameters may be given or left out.
        let order = "<tool_call>\n<function=place_order>\n"
        #expect(F.allows("<parameter=note>\nfragile\n</parameter>\n", constraint, after: order))
        // Undeclared functions are never opened; the framing is the template's.
        #expect(!F.allows("<tool_call>\n<function=delete_everything>", constraint, after: ""))
        // Whitespace before `<function=` is optional, as for the parser.
        #expect(F.allows("<tool_call><function=get_time>", constraint, after: ""))
        #expect(!F.allows("<tool_call>\n{\"name\": \"get_time\"", constraint, after: ""))
    }

    @Test func reasoningAndTextOutsideCallsStayFree() throws {
        let body = F.body(tools: F.order)
        for thinking in [false, true] {
            let constraint = try #require(try F.constraint(body, thinking: thinking))
            #expect(constraint.startsInReasoning == thinking)
            let free = constraint.allowedTokenIDs(state: constraint.initialState, remainingTokens: 10)
            // Every piece and every stop: the same choices as without a grammar.
            #expect(free.count == 256 + (248_044 - 256) + 4 + 2)
            #expect(free.contains(F.imEnd) && free.contains(F.toolCall))
        }
        let thinking = try #require(try F.constraint(body, thinking: true))
        // A call drafted inside the thought is not constrained: it is reasoning.
        let draft = "Let me call <tool_call>\n<function=nope>\n<parameter=x>\n\"anything\"\n"
        let afterDraft = try #require(F.walk(draft, thinking))
        #expect(thinking.allowedTokenIDs(state: afterDraft, remainingTokens: 10).contains(F.imEnd))
        // After the thought, prose may precede a call, and the call is constrained.
        let answer = draft + "</think>\n\nI will check.\n\n<tool_call>\n<function="
        let inCall = try #require(F.walk(answer, thinking))
        #expect(!thinking.allowedTokenIDs(state: inCall, remainingTokens: 10).contains(F.imEnd))
        #expect(F.walk("nope", thinking, from: inCall) == nil)
        // No answer can end inside a call; after it closes it can.
        let closed = try #require(F.walk("get_time>\n<parameter=city>\nRome\n</parameter>\n</function>\n</tool_call>",
                                         thinking, from: inCall))
        #expect(thinking.nextState(state: closed, tokenID: F.imEnd) == -1)
    }

    @Test func multipleCallsEachFollowTheirOwnSchema() throws {
        let body = F.body(tools: F.order)
        let constraint = try #require(try F.constraint(body))
        let second = "\n<tool_call>\n<function=get_time>\n<parameter=city>\nTokyo\n</parameter>\n</function>\n</tool_call>"
        let text = F.validOrder + second
        #expect(F.walk(text, constraint) != nil)
        let (request, prepared) = try F.prepared(body)
        let calls = try F.calls(text, request, prepared)
        #expect(calls.map(\.function.name) == ["place_order", "get_time"])
        // The second call's arguments are held to its own schema.
        #expect(!F.allows("\n<tool_call>\n<function=get_time>\n<parameter=count>", constraint, after: F.validOrder))
    }

    /// Text that only mentions the call marker is not a call the parser can
    /// read, so it stays text, as without the grammar; a call commits at
    /// `<function=`, and the JSON dialect is never opened.
    @Test func aMentionOfTheCallMarkerStaysText() throws {
        let body = F.body(tools: F.order)
        let constraint = try #require(try F.constraint(body))
        let (request, prepared) = try F.prepared(body)
        for mention in ["Wrap each call in <tool_call> tags.", "The <tool_call>\n<b>frame</b> is XML.",
                        "Use <tool_call>\n<functions> sparingly."] {
            // As the added token and as ordinary byte pieces alike.
            let end = try #require(F.walk(mention, constraint), "\(mention)")
            #expect(constraint.nextState(state: end, tokenID: F.imEnd) == -1)
            var state = constraint.initialState
            for byte in mention.utf8 {
                state = try #require(constraint.nextState(state: state, tokenID: Int(byte)))
            }
            #expect(try F.calls(mention, request, prepared).isEmpty)
            #expect(try F.streamedCalls(mention, body).isEmpty)
        }
        #expect(!F.allows("{\"name\"", constraint, after: "<tool_call>\n"))
        #expect(!F.allows("\u{00A0}", constraint, after: "<tool_call>"))
        #expect(!F.allows("x", constraint, after: "<tool_call>\n<function="))
        // Text after a mention is watched from its first byte on.
        #expect(!F.allows("<tool_call>\n<function=zzz", constraint, after: "<tool_call>"))
        #expect(F.allows("<tool_call>\n<function=get_time>", constraint, after: "<tool_call>"))
        // An answer may still end right after the marker, as before.
        let opened = try #require(F.walk("<tool_call>\n", constraint))
        #expect(constraint.nextState(state: opened, tokenID: F.imEnd) == -1)
    }

    /// `parallel_tool_calls: false`: no call opens after the first one closed.
    @Test func parallelToolCallsFalseAllowsOneCall() throws {
        let single = try #require(try F.constraint(F.body(tools: F.order, parallel: false)))
        let first = "<tool_call>\n<function=get_time>\n<parameter=city>\nRome\n</parameter>\n</function>\n</tool_call>"
        let closed = try #require(F.walk(first, single))
        #expect(F.walk("\n<tool_call>", single, from: closed) == nil)
        #expect(single.nextState(state: closed, tokenID: F.imEnd) == -1)
        let parallel = try #require(try F.constraint(F.body(tools: F.order, parallel: true)))
        #expect(F.walk(first + "\n" + first, parallel) != nil)
    }

    // MARK: - Schemas

    @Test func refsAndDefsAreInlinedLikeTheCoordinator() throws {
        let body = F.body(tools: F.refs)
        let constraint = try #require(try F.constraint(body))
        let call = "<tool_call>\n<function=book>\n<parameter=passengers>\n[{\"name\": \"Mia\", \"age\": "
        // The integer inside the referenced definition keeps its JSON type.
        #expect(F.allows("31}]\n</parameter>\n", constraint, after: call))
        #expect(!F.allows("\"31\"", constraint, after: call))
        let text = call + "31}]\n</parameter>\n<parameter=lead>\n{\"who\": {\"name\": \"Mia\", \"age\": 31}}\n</parameter>\n"
            + "</function>\n</tool_call>"
        #expect(F.walk(text, constraint) != nil)
        let (request, prepared) = try F.prepared(body)
        let arguments = try #require(try F.calls(text, request, prepared).first.map(F.arguments))
        #expect(arguments["lead"] == .object(["who": .object(["name": .string("Mia"), "age": .int(31)])]))
        // A top-level parameter that is a bare reference renders as a string to
        // the parser (the repair types it), so it stays unconstrained.
        let bare = #"[{"type":"function","function":{"name":"f","strict":true,"parameters":{"type":"object","#
            + #""$defs":{"P":{"type":"object","properties":{"a":{"type":"integer"}}}},"#
            + ##""properties":{"p":{"$ref":"#/$defs/P"}},"required":["p"]}}}]"##
        #expect(try F.constraint(F.body(tools: bare)) == nil)
        // Recursive references are not expanded.
        let recursive = #"[{"type":"function","function":{"name":"f","strict":true,"parameters":{"type":"object","#
            + ##""$defs":{"N":{"type":"object","properties":{"next":{"$ref":"#/$defs/N"}}}},"##
            + ##""properties":{"n":{"type":"object","properties":{"next":{"$ref":"#/$defs/N"}}}}}}}]"##
        #expect(try F.constraint(F.body(tools: recursive)) == nil)
    }

    @Test func anyOfWithNullAndOpenObjectUnionsCompile() throws {
        let body = F.body(tools: F.unions)
        let constraint = try #require(try F.constraint(body))
        let call = "<tool_call>\n<function=f>\n<parameter=limit>\n"
        #expect(F.allows("5\n</parameter>\n", constraint, after: call))
        #expect(F.allows("null\n</parameter>\n", constraint, after: call))
        #expect(!F.allows("\"5\"", constraint, after: call))
        let text = call + "null\n</parameter>\n<parameter=label>\nx\n</parameter>\n<parameter=flight>\n"
            + "{\"leg\": {\"anything\": [1, 2]}}\n</parameter>\n<parameter=legs>\n"
            + "[{\"number\": \"HAT1\", \"seats\": 2}, {\"x\": true}]\n</parameter>\n</function>\n</tool_call>"
        // The forwarded form's empty `properties` beside the union asserts nothing: any object.
        let legs = call + "null\n</parameter>\n<parameter=label>\nx\n</parameter>\n<parameter=legs>\n"
        #expect(F.allows("[{\"number\": \"HAT1\", \"seats\": 2}, {\"x\": true}]\n</parameter>\n", constraint, after: legs))
        #expect(!F.allows("[\"HAT1\"]", constraint, after: legs))
        #expect(F.walk(text, constraint) != nil)
        let (request, prepared) = try F.prepared(body)
        let arguments = try #require(try F.calls(text, request, prepared).first.map(F.arguments))
        #expect(arguments["limit"] == .null && arguments["label"] == .string("x"))
        #expect(arguments["legs"] == .array([.object(["number": .string("HAT1"), "seats": .int(2)]),
                                             .object(["x": .bool(true)])]))
        // A union of several types has no exact grammar here: unconstrained.
        let several = #"[{"type":"function","function":{"name":"f","strict":true,"parameters":{"type":"object","#
            + #""properties":{"v":{"anyOf":[{"type":"string"},{"type":"integer"}]}}}}}]"#
        #expect(try F.constraint(F.body(tools: several)) == nil)
    }

    @Test(arguments: [
        #"{"type":"string","pattern":"^a"}"#, #"{"type":"string","minLength":2}"#,
        #"{"type":"integer","minimum":1}"#, #"{"type":"number","multipleOf":2}"#,
        #"{"type":"array","items":{"type":"string"},"maxItems":64}"#, #"{"type":"array","items":{}}"#,
        #"{"type":"object","patternProperties":{"^x":{"type":"string"}}}"#, #"{"not":{"type":"string"}}"#,
        #"{"type":"array","items":{"type":"string"},"uniqueItems":true}"#, #"{"description":"anything"}"#,
        #"{"$ref":"https://example.com/schema.json"}"#, #"{"type":"null"}"#,
        #"{"anyOf":[{"type":"object"},{"type":"null"}],"properties":{"a":{}},"type":"object"}"#,
    ])
    func unsupportedSchemasStayUnconstrainedWithoutAnError(_ property: String) throws {
        let tools = #"[{"type":"function","function":{"name":"f","strict":true,"parameters":{"type":"object","#
            + #""properties":{"v":"# + property + #"},"required":["v"]}}}]"#
        #expect(try F.constraint(F.body(tools: tools)) == nil, "\(property)")
    }

    @Test func formatIsAnAnnotation() throws {
        let tools = #"[{"type":"function","function":{"name":"f","strict":true,"parameters":{"type":"object","#
            + #""properties":{"when":{"type":"string","format":"date-time"}},"required":["when"]}}}]"#
        #expect(try F.constraint(F.body(tools: tools)) != nil)
    }

    /// The parser's reading mirrored by `QwenStrictToolSchema.parserConversion`
    /// is the SDK's own: probe the real parser with each value shape.
    @Test func theParsersReadingMatchesTheCallParser() throws {
        let schemas = [
            #"{"type":"string"}"#, #"{"type":"integer"}"#, #"{"type":"number"}"#, #"{"type":"boolean"}"#,
            #"{"type":"object"}"#, #"{"type":"array"}"#, #"{"type":"integer","nullable":true}"#,
            #"{"type":["integer","null"]}"#, #"{"type":["string","integer"]}"#, #"{"type":"null"}"#,
            #"{"anyOf":[{"type":"integer"},{"type":"null"}]}"#, #"{"anyOf":[{"type":"string"},{"type":"integer"}]}"#,
            #"{"allOf":[{"type":"number"},{"type":"integer"}]}"#, ##"{"$ref":"#/x","type":"string"}"##,
            #"{"type":"int"}"#, #"{"type":"dict"}"#, #"{"type":"weird"}"#, #"{"enum":["a"]}"#, "{}",
            #"{"type":"Integer"}"#, #"{"type":"object","nullable":1}"#,
        ]
        let probes: [(String, MLXLMCommon.JSONValue?)] = [
            ("5", .int(5)), ("2.5", .double(2.5)), ("true", .bool(true)), ("{}", .object([:])), ("[]", .array([])),
            ("null", .null),
        ]
        let parser = Qwen35ToolCallParser(startTag: "<tool_call>", endTag: "</tool_call>")
        for raw in schemas {
            let schema = try JSONDecoder().decode(MLXLMCommon.JSONValue.self, from: Data(raw.utf8))
            let tool = OpenAITool(function: .init(name: "f", parameters: .object([
                "type": .string("object"), "properties": .object(["v": schema])])))
            let conversion = QwenStrictToolSchema.parserConversion(schema)
            for (text, converted) in probes {
                let frame = "<tool_call>\n<function=f>\n<parameter=v>\n\(text)\n</parameter>\n</function>\n</tool_call>"
                let value = try #require(parser.parse(content: frame, tools: [tool.toolSpec()])?.function.arguments["v"])
                let expected: Bool
                switch (conversion.kind, text) {
                case (_, "null") where conversion.kind != .text: expected = conversion.acceptsNull
                case (.integer, "5"), (.number, "5"), (.number, "2.5"), (.boolean, "true"), (.object, "{}"),
                     (.array, "[]"): expected = true
                default: expected = false
                }
                #expect((value == converted) == expected, "\(raw) reading \(text): \(value)")
            }
        }
    }

    /// The streamed reading mirrored by `QwenStrictToolSchema.streamsAsText`:
    /// a parameter streamed as text whose parsed value is not that text makes
    /// the streamed call diverge, which is why such parameters are declined.
    @Test func theStreamedReadingMatchesTheStreamer() throws {
        let schemas = [
            #"{"type":"string"}"#, #"{"type":"integer"}"#, #"{"type":"number"}"#, #"{"type":"boolean"}"#,
            #"{"type":"object"}"#, #"{"type":"array"}"#, #"{"type":"null"}"#, #"{"type":"integer","nullable":true}"#,
            #"{"type":"weird"}"#, #"{"type":"Integer"}"#, #"{"type":"enum"}"#, #"{"type":"dict"}"#, "{}",
            #"{"anyOf":[{"type":"integer"},{"type":"null"}]}"#, #"{"type":["integer","null"]}"#,
        ]
        let parser = Qwen35ToolCallParser(startTag: "<tool_call>", endTag: "</tool_call>")
        for raw in schemas {
            let schema = try JSONDecoder().decode(MLXLMCommon.JSONValue.self, from: Data(raw.utf8))
            let tool = OpenAITool(function: .init(name: "f", parameters: .object([
                "type": .string("object"), "properties": .object(["v": schema])])))
            for probe in ["5", "true", "null", "{}", "x"] {
                let frame = "<tool_call>\n<function=f>\n<parameter=v>\n\(probe)\n</parameter>\n</function>\n</tool_call>"
                let parsed = try #require(parser.parse(content: frame, tools: [tool.toolSpec()])?.function.arguments["v"])
                let handler = BatchedToolStreamHandler(format: .qwen35, tools: [tool.toolSpec()],
                    streaming: ToolCallStreamingOptions(exposesName: { _ in true }))
                let segments = handler.processChunkSegments(frame) + handler.finishSegments()
                let failed = segments.contains { if case .callFailed = $0 { true } else { false } }
                let expected = QwenStrictToolSchema.streamsAsText(schema) && parsed != .string(probe)
                #expect(failed == expected, "\(raw) streaming \(probe): \(segments)")
            }
        }
    }

    // MARK: - Property: whatever the masks admit parses to valid arguments

    /// Random calls drawn from the masks alone (printable bytes, any order of
    /// parameters, any lengths), closed with the shortest framing once long
    /// enough. Every call they produce must parse to arguments the strict
    /// check accepts, and stream as the same call.
    @Test(arguments: ["place_order", "get_time", "book", "f"])
    func callsDrawnFromTheMasksAlwaysValidate(_ function: String) throws {
        let body = F.body(tools: ["book": F.refs, "f": F.unions][function] ?? F.order)
        let constraint = try #require(try F.constraint(body))
        let (request, prepared) = try F.prepared(body)
        let closers = ["\n</parameter>\n", "\"", "]", "}", "</function>\n</tool_call>"]
        var random = StrictGrammarRandom(seed: UInt64(function.utf8.count))
        for _ in 0..<60 {
            var text = "<tool_call>\n<function=\(function)>\n"
            var state = try #require(F.walk(text, constraint))
            var steps = 0
            while !constraint.allowedTokenIDs(state: state, remainingTokens: 10).contains(F.imEnd), steps < 4_000 {
                steps += 1
                if steps > 40 || random.next() % 8 == 0,
                   let closer = closers.first(where: { F.walk($0, constraint, from: state) != nil }) {
                    state = try #require(F.walk(closer, constraint, from: state))
                    text += closer
                    continue
                }
                let candidates = constraint.allowedTokenIDs(state: state, remainingTokens: 10)
                    .filter { (32...126).contains($0) || $0 == 10 }
                let token = try #require(candidates.randomElement(using: &random))
                state = try #require(constraint.nextState(state: state, tokenID: token))
                text += String(UnicodeScalar(UInt8(token)))
            }
            #expect(steps < 4_000, "the draw closed its call")
            let calls = try F.calls(text, request, prepared)
            #expect(calls.count == 1 && calls[0].function.name == function, "\(text)")
            let streamed = try F.streamedCalls(text, body)
            #expect(streamed.map(\.function.name) == calls.map(\.function.name), "\(text)")
            #expect(streamed.map(\.function.arguments) == calls.map(\.function.arguments), "\(text)")
        }
    }

    // MARK: - Policy

    @Test func autoStrictRequestsTakeTheGrammarRequiredAndOthersDoNot() throws {
        #expect(try F.constraint(F.body(tools: F.order)) != nil)
        #expect(try F.constraint(F.body(tools: F.order, choice: #""auto""#)) != nil)
        for choice in [#""required""#, #"{"type":"function","function":{"name":"get_time"}}"#, #""none""#] {
            #expect(try F.constraint(F.body(tools: F.order, choice: choice)) == nil, "\(choice)")
        }
        // Without `strict`, calls are returned as generated: no grammar unless asked for every tool.
        let loose = F.order.replacingOccurrences(of: #""strict":true,"#, with: "")
        #expect(try F.constraint(F.body(tools: loose)) == nil)
        #expect(try F.constraint(F.body(tools: loose), allTools: true) != nil)
        // One strict tool holds every call of the request to its schema, so all are constrained.
        let mixed = F.order.replacingOccurrences(of: #""name":"get_time","strict":true"#, with: #""name":"get_time""#)
        let constraint = try #require(try F.constraint(F.body(tools: mixed)))
        #expect(!F.allows("<parameter=zone>", constraint, after: "<tool_call>\n<function=get_time>\n"))
    }

    @Test func otherEnginesFamiliesAndBoundariesKeepTodaysCalls() throws {
        let body = F.body(tools: F.order)
        // Cluster pairs and native-tracked engines run no token constraint.
        #expect(try F.constraint(body, runsTokenConstraints: false) == nil)
        for type in ["qwen4_exp", "prism_hadamard_qwen35", "gemma4", "nemotron_h", "gpt_oss", "mimo_v2"] {
            #expect(try F.constraint(body, modelType: type) == nil, "\(type)")
        }
        #expect(try F.constraint(body, setting: .off) == nil)
        let (request, prepared) = try F.prepared(body)
        func make(prompt: String? = nil, parser: ToolCallFormat? = .qwen35,
                  handle: TokenizerHandle = F.handle) -> QwenStrictToolConstraint? {
            QwenStrictToolGrammar.constraint(prepared: prepared, request: request, parser: parser, tokenizer: handle,
                modelType: "qwen3_5", defaultMaxTokens: 512, stopTokenIDs: F.stops,
                promptTokens: QwenByteTestTokenizer.tokens(prompt ?? QwenByteTestTokenizer.prompt(thinking: false)),
                runsTokenConstraints: true, setting: F.qwenTypes, allTools: false)
        }
        #expect(make() != nil)
        #expect(make(prompt: "<|im_start|>assistant\n") == nil)
        #expect(make(parser: .xmlFunction) == nil)
        let moved = QwenByteTestTokenizer.pinned.map { $0.0 == "<tool_call>" ? ($0.0, 248_070) : $0 }
        #expect(make(handle: TokenizerHandle(QwenByteTestTokenizer(markers: moved))) == nil)
    }

    @Test func theSwitchIsPerModelAndReachesTheProviderJob() {
        typealias G = QwenStrictToolGrammar
        #expect(G.environmentKey == "DARKBLOOM_STRICT_TOOL_GRAMMAR")
        // By default the MoE builds (Qwen 3.6, Qwen 3.5 35B), which do not draft by default, and Qwen 3.8 27B,
        // whose strict calls are its main failure (a coordinator switch turns it off centrally); the 9B only when a
        // Mac opts in.
        let byDefault = G.setting(environment: [:])
        #expect(byDefault == .models(["qwen3_5_moe", "qwen3.8-27b"]))
        #expect(G.isEnabled(modelId: "qwen3.6-35b-a3b-vl-mtp-mxfp8", modelType: "qwen3_5_moe", setting: byDefault))
        #expect(G.isEnabled(modelId: "Qwen3.5-35B-A3B", modelType: "qwen3_5_moe", setting: byDefault))
        #expect(G.isEnabled(modelId: "EigenLabs/Qwen3.8-27B-4bit-mtp", modelType: "qwen3_5", setting: byDefault))
        #expect(!G.isEnabled(modelId: "Qwen3.5-9B", modelType: "qwen3_5", setting: byDefault))
        #expect(!G.isEnabled(modelId: "EigenLabs/Qwen3.5-9B-MLX-4bit-mtp", modelType: "qwen3_5", setting: byDefault))
        #expect(G.setting(environment: [G.environmentKey: ""]) == byDefault)
        // An on word opts every Qwen 3.5-family build in.
        #expect(G.setting(environment: [G.environmentKey: " On "]) == .models(["qwen3_5", "qwen3_5_moe"]))
        #expect(G.isEnabled(modelId: "EigenLabs/Qwen3.8-27B-4bit-mtp", modelType: "qwen3_5",
                            setting: G.setting(environment: [G.environmentKey: "1"])))
        for off in ["off", "0", "FALSE", " no ", "none", "Disabled"] {
            #expect(G.setting(environment: [G.environmentKey: off]) == .off, "\(off)")
        }
        let listed = G.setting(environment: [G.environmentKey: "Qwen3.8-27B, qwen3_5_moe"])
        #expect(listed == .models(["qwen3.8-27b", "qwen3_5_moe"]))
        #expect(G.isEnabled(modelId: "EigenLabs/Qwen3.8-27B-4bit-mtp", modelType: "qwen3_5", setting: listed))
        #expect(!G.isEnabled(modelId: "EigenLabs/Qwen3.5-9B-MLX-4bit-mtp", modelType: "qwen3_5", setting: listed))
        #expect(G.isEnabled(modelId: "qwen3.6-35b-a3b-vl-mtp-mxfp8", modelType: "qwen3_5_moe", setting: listed))
        // A list replaces the default builds: one without Qwen 3.8 turns it off on that Mac.
        #expect(!G.isEnabled(modelId: "EigenLabs/Qwen3.8-27B-4bit-mtp", modelType: "qwen3_5",
                             setting: G.setting(environment: [G.environmentKey: "qwen3_5_moe"])))
        // Only the Qwen 3.5 template's builds qualify, whatever the list says.
        #expect(!G.isEnabled(modelId: "gemma-4-26b", modelType: "gemma4",
                             setting: G.setting(environment: [G.environmentKey: "gemma4,gemma"])))
        #expect(!G.allTools(environment: [:]) && G.allTools(environment: [G.allToolsEnvironmentKey: "1"]))
        let keys = [G.environmentKey, G.allToolsEnvironmentKey]
        #expect(keys.allSatisfy { LaunchAgent.inferencePassthroughEnvKeys.contains($0) })
        let values = [G.environmentKey: "off", G.allToolsEnvironmentKey: "on"]
        #expect(LaunchAgent.passthroughEnvironment(from: values.merging(["UNRELATED": "x"]) { a, _ in a }) == values)
    }

    // MARK: - Streaming

    /// The constrained call streams as OpenAI fragments: the name first, then
    /// arguments that add up to the validated call.
    @Test func aConstrainedCallStreamsAsDeltas() throws {
        var request = try F.prepared(F.body(tools: F.order)).0
        request.streamToolCallDeltas = true
        var prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "qwen3_5")
        prepared.declaredTools = try F.prepared(F.body(tools: F.order)).1.declaredTools
        let constraint = try #require(try F.constraint(F.body(tools: F.order)))
        #expect(F.walk(F.validOrder, constraint) != nil)
        for chunking in [1, 3, 17] {
            let handler = try #require(try ToolStreamPreparation.makeHandler(
                request: request, prepared: prepared, modelType: "qwen3_5", streamToolCalls: true))
            #expect(handler.streamsCalls)
            var router = NativeToolStreamRouter(handler: handler, requiresToolCall: false, nativePrefix: nil,
                streamedCalls: prepared)
            var events: [MLXServerGenerationEvent] = []
            let characters = Array(F.validOrder)
            for start in stride(from: 0, to: characters.count, by: chunking) {
                events += try router.process(String(characters[start..<min(start + chunking, characters.count)]))
            }
            events += try router.finishText()
            events += try router.finishToolCalls(truncated: false)
            let deltas = events.compactMap { if case .toolCallDelta(let delta) = $0 { delta } else { nil } }
            #expect(deltas.first?.name == "place_order" && deltas.allSatisfy { $0.index == 0 })
            let completed = try #require(deltas.last?.completed)
            let streamed = deltas.map(\.arguments).joined()
            #expect(try JSONDecoder().decode([String: MLXLMCommon.JSONValue].self, from: Data(streamed.utf8))
                == completed.function.arguments, "chunks of \(chunking)")
            #expect(router.completedToolCalls == [completed])
        }
    }
}

/// Whole answers drawn from the masks from the first token on, over a
/// vocabulary with multi-byte pieces (split and spelled markers, mentions,
/// Unicode whitespace, the JSON dialect, escapes): every mask is exactly the
/// set `nextState` accepts, and every call either reader returns is one the
/// grammar opened and closed.
@Suite("Strict tool grammar: whole answers over multi-byte pieces")
struct QwenStrictToolWholeAnswerTests {
    private typealias F = StrictToolFixture
    static let multiBytePieces: [String] = [
        "<tool", "_call", ">", " tags", "\n<", "<function=", "<function=get_time>", "\n<function=get_time>\n",
        " {", "{\"", "\u{00A0}", " \u{00A0}", "\u{2028}", "\u{0085}", "\n\n", "  ", "x>", "<b>", "<func", "tion=",
        "get_time", "place_order", ">\n", "\n<parameter=city>\n", "<parameter=", "city", ">\nRome",
        "Rome\n</parameter>\n", "\n</parameter>\n", "</parameter>", "</function>\n</tool_call>", "</function>",
        "\n</tool_call>", "</tool_call>", "\t<", "\n<function=place_order>\n", "<tool_call>\n<function=get_time>\n",
        "é", "\\u", "ud83d", "\r\n", " \n", "<|im_end|>", "<think>", "</think>", "<tool_call> ",
        " {\"name\": \"get_time\", \"arguments\": {\"city\": \"x\"}}", "<tool_call>{", "\n<function=zzz>",
        "\u{00A0}<function=get_time>", " \u{0085}\n", "<tool_call>\n<b>", "s>",
        "\n<function=get_time>\n<parameter=city>\nRome\n</parameter>\n</function>\n</tool_call>",
    ]
    static let firstMultiBytePiece = 300

    static func vocabulary() throws -> JSONAnswerVocabulary {
        let profile = QwenStrictToolGrammar.profile
        var pieces = [[UInt8]](repeating: [], count: profile.vocabularySize)
        for byte in 0..<256 { pieces[byte] = [UInt8(byte)] }
        for (offset, text) in multiBytePieces.enumerated() { pieces[firstMultiBytePiece + offset] = Array(text.utf8) }
        for token in profile.pieceTokens + profile.answerEOS { pieces[token.id] = Array(token.spelling.utf8) }
        return try JSONAnswerVocabulary(pieces: pieces, profile: profile, stopTokenIDs: F.stops)
    }

    static func constraint(parallel: Bool, vocabulary: JSONAnswerVocabulary) throws -> QwenStrictToolConstraint {
        let (_, prepared) = try F.prepared(F.body(tools: F.order, parallel: parallel))
        let schema = try QwenStrictToolSchema(declared: try #require(prepared.declaredTools),
            rendered: try #require(prepared.tools), forbidding: QwenStrictToolGrammar.forbiddenMarkers,
            family: QwenStrictToolGrammar.profile.family)
        return try QwenStrictToolConstraint(schema: schema, vocabulary: vocabulary,
            forbidding: QwenStrictToolGrammar.forbiddenMarkers, startsInReasoning: false,
            allowsParallelCalls: parallel, maxTokens: 4096)
    }

    /// The mask is the sorted set of pieces and stops `nextState` accepts, the same on every call.
    static func maskMatchesSimulation(_ constraint: QwenStrictToolConstraint, _ vocabulary: JSONAnswerVocabulary,
                                      state: Int) -> Bool {
        let mask = constraint.allowedTokenIDs(state: state, remainingTokens: 100)
        let expected = (vocabulary.pieceTokenIDs + F.stops).sorted()
            .filter { constraint.nextState(state: state, tokenID: $0) != nil }
        return mask == expected && constraint.allowedTokenIDs(state: state, remainingTokens: 100) == mask
    }

    @Test(arguments: [true, false])
    func openingMasksMatchSimulation(_ parallel: Bool) throws {
        let vocabulary = try Self.vocabulary()
        let constraint = try Self.constraint(parallel: parallel, vocabulary: vocabulary)
        let call = "<tool_call>\n<function=get_time>\n<parameter=city>\nRome\n</parameter>\n</function>\n</tool_call>"
        for prefix in ["", "<tool_call>", "<tool_call>\n", "<tool_call> \t\n", "<tool_call>\n<", "<tool_call>\n<func",
                       "<tool_call>\n<function", "x <tool_call>", "<tool_call>\n<b", call, call + "\n",
                       "<tool_call> tags <tool_call>\n"] {
            var state = constraint.initialState
            for byte in prefix.utf8 {
                state = try #require(constraint.nextState(state: state, tokenID: Int(byte)), "\(prefix.debugDescription)")
            }
            #expect(Self.maskMatchesSimulation(constraint, vocabulary, state: state), "\(prefix.debugDescription)")
        }
    }

    @Test(arguments: [(UInt64(1), true), (UInt64(2), false)])
    func answersDrawnFromTheMasksOnlyCallWhatTheGrammarHeld(_ seed: UInt64, _ parallel: Bool) throws {
        let vocabulary = try Self.vocabulary()
        let constraint = try Self.constraint(parallel: parallel, vocabulary: vocabulary)
        let body = F.body(tools: F.order, parallel: parallel)
        let (request, prepared) = try F.prepared(body)
        let parser = Qwen35ToolCallParser(startTag: "<tool_call>", endTag: "</tool_call>")
        let specs = try #require(prepared.tools).map { $0.toolSpec() }
        let markers = QwenStrictToolMarkers(forbidding: QwenStrictToolGrammar.forbiddenMarkers, singleCall: !parallel)
        let ascii = Set(Array(32...126) + [10])
        let multiBytePieces = Set(Self.firstMultiBytePiece..<(Self.firstMultiBytePiece + Self.multiBytePieces.count))
        var random = StrictGrammarRandom(seed: seed)
        var finished = 0
        for _ in 0..<100 {
            var state = constraint.initialState
            var bytes: [UInt8] = []
            var ended = false
            for step in 0..<500 {
                let allowed = constraint.allowedTokenIDs(state: state, remainingTokens: 100)
                if step % 25 == 0 { #expect(Self.maskMatchesSimulation(constraint, vocabulary, state: state)) }
                if allowed.contains(F.imEnd), step > 30, Int.random(in: 0..<40, using: &random) == 0 {
                    ended = true
                    break
                }
                let multi = allowed.filter(multiBytePieces.contains)
                let pool = !multi.isEmpty && Bool.random(using: &random) ? multi : allowed.filter(ascii.contains)
                let token = try #require(pool.randomElement(using: &random))
                state = try #require(constraint.nextState(state: state, tokenID: token))
                bytes += vocabulary.pieces[token]
            }
            guard ended else { continue }
            finished += 1
            // Replay the bytes: the calls the grammar opened at `<function=` and closed.
            var boundary = QwenStrictToolBoundary(reasoning: false)
            var held: [[String: MLXLMCommon.JSONValue]] = []
            var frame: [UInt8] = []
            for byte in bytes {
                let inside = !boundary.isFree
                let consumed = boundary.consume(byte, schema: constraint.schema, markers: markers)
                #expect(consumed)
                if inside { frame.append(byte) }
                if inside, boundary.isFree {
                    let call = parser.parse(content: "<tool_call>\n<function=" + String(decoding: frame, as: UTF8.self),
                                            tools: specs)
                    #expect(call != nil, "\(frame)")
                    if let call { held.append(call.function.arguments) }
                    frame = []
                }
            }
            let text = String(decoding: bytes, as: UTF8.self)
            let calls = try F.calls(text, request, prepared)
            let streamed = try F.streamedCalls(text, body)
            #expect(parallel || calls.count <= 1)
            for call in calls + streamed {
                #expect(held.contains(call.function.arguments), "\(text.debugDescription)")
            }
        }
        #expect(finished > 80)
    }
}

/// Deterministic generator for the property test.
private struct StrictGrammarRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Samples a fixed script through the submitted constraint like a model whose
/// sampler applies the masks: a scripted token the mask refuses is never
/// drawn, so it is skipped. Without a constraint the script is emitted as is.
private final class MaskedScriptEngine: CBv2Engine, @unchecked Sendable {
    private let script: [Int]
    private let lock = NSLock()
    private var requests: [CBv2Request] = []

    init(script: String) { self.script = QwenByteTestTokenizer.tokens(script) }

    var submitted: [CBv2Request] { lock.withLock { requests } }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        if let constraint = request.tokenConstraint, constraint.maxTokens != request.maxTokens {
            throw CBv2SchedulerError.tokenConstraintBudgetMismatch(
                request: request.maxTokens, constraint: constraint.maxTokens)
        }
        lock.withLock { requests.append(request) }
        var deltas: [(text: String, token: Int)] = []
        var finish = CBv2FinishReason.length
        var state = request.tokenConstraint?.initialState ?? 0
        var next = 0
        while deltas.count < request.maxTokens {
            var token: Int?
            if let constraint = request.tokenConstraint {
                let allowed = constraint.allowedTokenIDs(state: state, remainingTokens: request.maxTokens - deltas.count)
                while next < script.count, !Self.contains(allowed, script[next]) { next += 1 }
                if next < script.count {
                    token = script[next]
                    next += 1
                } else {
                    token = allowed.first(where: request.stopTokens.contains)
                }
                if let token { state = constraint.nextState(state: state, tokenID: token) ?? state }
            } else {
                token = next < script.count ? script[next] : request.stopTokens.min()
                next += 1
            }
            guard let token else { break }
            if request.stopTokens.contains(token) {
                deltas.append(("", token))
                finish = .stop
                break
            }
            deltas.append((String(decoding: QwenByteTestTokenizer.piece(token), as: UTF8.self), token))
        }
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        for delta in deltas { continuation.yield(.delta(text: delta.text, tokens: [delta.token], logprobs: nil)) }
        continuation.yield(.finished(reason: finish,
            usage: CBv2Usage(promptTokens: request.promptTokens.count, completionTokens: deltas.count)))
        continuation.finish()
        return stream
    }

    private static func contains(_ sorted: [Int], _ token: Int) -> Bool {
        var low = 0, high = sorted.count
        while low < high {
            let middle = (low + high) / 2
            if sorted[middle] < token { low = middle + 1 } else { high = middle }
        }
        return low < sorted.count && sorted[low] == token
    }

    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        .init(activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0, kvBytesCapacity: 0, activeTokens: 0)
    }
    func shutdown() async {}
}

/// Client view of one stream: reasoning and text through the qwen3 parser,
/// as downstream of the scheduler, and the streamed calls.
private struct StrictToolOutcome {
    var content = ""
    var reasoning = ""
    var deltas: [ServerToolCallDelta] = []
    var info: ServerGenerationInfo?
    var error: (any Error)?
    private var parser = StreamingReasoningParser(format: .qwen3)

    var calls: [ToolCall] { deltas.compactMap(\.completed) }

    mutating func record(_ event: MLXServerGenerationEvent) {
        switch event {
        case .content(let text): parser.parse(text).forEach { apply($0) }
        case .parsed(let parsed): apply(parsed)
        case .toolCallDelta(let delta): deltas.append(delta)
        case .info(let info): self.info = info
        case .toolCall, .logprobs: break
        }
    }

    mutating func finish() { parser.finish().forEach { apply($0) } }

    private mutating func apply(_ parsed: ParsedReasoning) {
        content += parsed.content
        reasoning += parsed.reasoningContent ?? ""
    }
}

@Suite("Strict tool grammar through the scheduler and bridge")
struct QwenStrictToolServingTests {
    private static let tokenizer = TokenizerHandle(QwenByteTestTokenizer())
    private static let tools = #"""
    [{"type":"function","function":{"name":"get_time","strict":true,"parameters":{"type":"object",
      "properties":{"city":{"type":"string"},"offset":{"type":"integer"},
                    "zone":{"type":"object","properties":{"dst":{"type":"boolean"}},"required":["dst"],
                            "additionalProperties":false}},
      "required":["city","offset","zone"],"additionalProperties":false}}}]
    """#
    /// What the model would write: the offset quoted, the flag as a word.
    private static let script = "Need the time.</think>\n\n<tool_call>\n<function=get_time>\n"
        + "<parameter=city>\nRome\n</parameter>\n<parameter=offset>\n\"5\"\n</parameter>\n"
        + "<parameter=zone>\n{\"dst\": yes true}\n</parameter>\n</function>\n</tool_call><|im_end|>"

    /// Builds the grammar is on for by default (Qwen 3.6, Qwen 3.8), and one a Mac opts in (the 9B). The
    /// scheduler reads the switch from the process environment, so these expect `DARKBLOOM_STRICT_TOOL_GRAMMAR`
    /// unset.
    private static let moe = (id: "qwen3.6-35b-a3b-vl-mtp-mxfp8", type: "qwen3_5_moe")
    private static let qwen38 = (id: StrictToolFixture.model, type: "qwen3_5")
    private static let nineB = (id: "Qwen3.5-9B", type: "qwen3_5")

    private func serve(_ engine: MaskedScriptEngine, tools: String = tools, strict: Bool = true,
                       build: (id: String, type: String) = moe) async throws -> StrictToolOutcome {
        let id = build.id
        let bridge = EngineV2Bridge(engine: engine, modelId: id, tokenizer: Self.tokenizer,
            eosTokenIds: [248046, 248044], defaultMaxTokens: 512, maxConcurrentRequests: 1)
        let tokenizer = Self.tokenizer
        let scheduler = MultiModelBatchSchedulerEngine(registryProvider: {
            [id: .init(tokenizer: tokenizer, modelType: build.type, engineV2Bridge: bridge)]
        })
        let declared = strict ? tools : tools.replacingOccurrences(of: #""strict":true,"#, with: "")
        let body = StrictToolFixture.body(tools: declared, model: id)
        var request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self,
            from: ToolSchemaNormalization.ensureParameterTypes(in: Data(body.utf8)))
        request.stream = true
        request.streamToolCallDeltas = true
        var outcome = StrictToolOutcome()
        do {
            for try await event in try await scheduler.streamChatCompletion(request: request) { outcome.record(event) }
        } catch { outcome.error = error }
        outcome.finish()
        await bridge.shutdown()
        return outcome
    }

    @Test func aStrictCallThatWouldMissItsSchemaStreamsValid() async throws {
        let engine = MaskedScriptEngine(script: Self.script)
        let outcome = try await serve(engine)
        let constraint = try #require(engine.submitted.first?.tokenConstraint as? QwenStrictToolConstraint)
        #expect(constraint.startsInReasoning && constraint.maxTokens == engine.submitted.first?.maxTokens)
        #expect(outcome.error == nil)
        #expect(outcome.reasoning == "Need the time.")
        let call = try #require(outcome.calls.first)
        #expect(outcome.calls.count == 1 && call.function.name == "get_time")
        #expect(call.function.arguments == ["city": .string("Rome"), "offset": .int(5),
                                            "zone": .object(["dst": .bool(true)])])
        #expect(outcome.deltas.first?.name == "get_time", "the call streams name first")
        #expect(outcome.deltas.count > 2, "and its arguments as they are generated")
    }

    @Test func withoutStrictTheCallIsReturnedAsGeneratedAsBefore() async throws {
        let engine = MaskedScriptEngine(script: Self.script)
        let outcome = try await serve(engine, strict: false)
        #expect(engine.submitted.first?.tokenConstraint == nil)
        #expect(outcome.error == nil)
        #expect(outcome.calls.first?.function.arguments["offset"] == .string("\"5\""))
    }

    /// Qwen 3.8 takes the grammar by default; the 9B, which drafts with MTP
    /// that a constrained row stops, is served as before unless the Mac opts in.
    @Test func qwen38TakesTheGrammarByDefaultAndThe9BDoesNot() async throws {
        let engine = MaskedScriptEngine(script: Self.script)
        let outcome = try await serve(engine, build: Self.qwen38)
        #expect(engine.submitted.first?.tokenConstraint is QwenStrictToolConstraint)
        #expect(outcome.error == nil && outcome.calls.first?.function.arguments["offset"] == .int(5))
        let nineB = MaskedScriptEngine(script: Self.script)
        _ = try await serve(nineB, build: Self.nineB)
        #expect(!nineB.submitted.isEmpty)
        #expect(nineB.submitted.first?.tokenConstraint == nil)
    }
}

/// Run against a local Qwen 3.5/3.6/3.8 snapshot (tokenizer and template files
/// only; no weights are read): `DARKBLOOM_TEST_QWEN_TOKENIZER_DIR=<snapshot>`.
@Suite("Strict tool grammar real tokenizer",
       .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_TEST_QWEN_TOKENIZER_DIR"] != nil))
struct QwenStrictToolRealTokenizerTests {
    @Test func theShippedTokenizerWalksARealCall() async throws {
        let directory = URL(fileURLWithPath: try #require(
            ProcessInfo.processInfo.environment["DARKBLOOM_TEST_QWEN_TOKENIZER_DIR"]))
        let tokenizer = try await LocalTokenizerLoader(environment: [:]).load(from: directory)
        let clock = ContinuousClock()
        let started = clock.now
        let vocabulary = try JSONAnswerVocabulary(tokenizer: tokenizer, profile: QwenStrictToolGrammar.profile,
            stopTokenIDs: StrictToolFixture.stops)
        let elapsed = clock.now - started
        // The base pieces and the four markers; stop tokens are sampled separately.
        #expect(vocabulary.pieceTokenIDs.count == 248_044 + 4)
        let (request, prepared) = try StrictToolFixture.prepared(StrictToolFixture.body(tools: StrictToolFixture.order))
        let tools = try #require(prepared.tools).map { $0.toolSpec() }
        for thinking in [true, false] {
            let prompt = try tokenizer.applyChatTemplate(messages: [["role": "user", "content": "Order it."]],
                tools: tools, additionalContext: ["enable_thinking": thinking])
            let schema = try QwenStrictToolSchema(declared: try #require(prepared.declaredTools),
                rendered: try #require(prepared.tools), forbidding: QwenStrictToolGrammar.forbiddenMarkers,
                family: QwenStrictToolGrammar.profile.family)
            let tail = tokenizer.decode(tokenIds: Array(prompt.suffix(ReasoningPromptProbe.tailTokenCount)),
                skipSpecialTokens: false)
            let prefix = try #require(ReasoningPromptProbe.streamingPrefix(forPromptTail: tail))
            #expect((prefix == ReasoningPromptProbe.thinkOpen) == thinking)
            let constraint = try QwenStrictToolConstraint(schema: schema, vocabulary: vocabulary,
                forbidding: QwenStrictToolGrammar.forbiddenMarkers, startsInReasoning: thinking, maxTokens: 4096)
            let answer = (thinking ? "The user wants an order.\n</think>\n\n" : "") + StrictToolFixture.validOrder
            var state = constraint.initialState
            for token in tokenizer.encode(text: answer, addSpecialTokens: false) {
                #expect(constraint.allowedTokenIDs(state: state, remainingTokens: 100).contains(token), "token \(token)")
                state = try #require(constraint.nextState(state: state, tokenID: token), "token \(token)")
            }
            #expect(constraint.nextState(state: state, tokenID: 248046) == -1)
            _ = request
        }
        print("qwen-strict-tool-vocabulary-build: \(elapsed)")
    }
}
