import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

enum GPTOSSAutoFixture {
    typealias F = GPTOSSForcedFixture
    typealias T = HarmonyByteTestTokenizer

    /// A function whose schema is outside the compiled subset (`anyOf`).
    static var search: [String: Any] { ["type": "function", "function": [
        "name": "search",
        "parameters": [
            "type": "object",
            "properties": ["query": ["anyOf": [["type": "string"], ["type": "integer"]]]],
            "required": ["query"],
        ] as [String: Any],
    ] as [String: Any]] }

    static func tool(_ name: String, _ parameters: [String: Any]) -> [String: Any] {
        ["type": "function", "function": ["name": name, "parameters": parameters] as [String: Any]]
    }

    static func parameters(_ json: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    /// Booking with a local `$ref` to a passenger object (Tau2's shape).
    static var book: [String: Any] {
        tool("book", [
            "type": "object",
            "$defs": ["Passenger": [
                "type": "object", "properties": ["name": ["type": "string"]], "required": ["name"],
                "additionalProperties": false,
            ] as [String: Any]],
            "properties": ["passengers": ["type": "array", "items": ["$ref": "#/$defs/Passenger"]]],
            "required": ["passengers"],
            "additionalProperties": false,
        ])
    }

    /// `book` as the coordinator or the local API sends it once they inline
    /// its references: the prompt shows the passenger object.
    static var bookInlined: [String: Any] {
        tool("book", [
            "type": "object",
            "properties": ["passengers": ["type": "array", "items": [
                "type": "object", "properties": ["name": ["type": "string"]], "required": ["name"],
                "additionalProperties": false,
            ] as [String: Any]] as [String: Any]],
            "required": ["passengers"],
            "additionalProperties": false,
        ])
    }

    /// Pydantic's `Optional[...]` fields as the coordinator forwards them: its
    /// render repair writes `type`, `nullable` (and an empty `properties` for
    /// an object) beside each nullable `anyOf`; `priority` carries value limits.
    static var createIssueRouted: [String: Any] {
        func optional(_ branch: [String: Any], type: String, extra: [String: Any] = [:]) -> [String: Any] {
            let null: [String: Any] = ["type": "null"]
            let union: [String: Any] = ["anyOf": [branch, null], "default": NSNull(), "type": type, "nullable": true]
            return union.merging(extra) { first, _ in first }
        }
        let name: [String: Any] = ["type": "string"]
        let label: [String: Any] = [
            "type": "object", "required": ["name"],
            "properties": ["name": name, "color": optional(name, type: "string")] as [String: Any],
        ]
        let labels: [String: Any] = ["type": "array", "items": label]
        let priority: [String: Any] = ["type": "integer", "minimum": 0, "maximum": 4]
        let id: [String: Any] = ["type": "integer"]
        let assignee: [String: Any] = ["type": "object", "properties": ["id": id] as [String: Any], "required": ["id"]]
        let emptyProperties: [String: Any] = [:]
        let ids: [String: Any] = ["type": "array", "nullable": true, "items": id]
        return tool("create_issue", [
            "type": "object",
            "properties": [
                "title": name,
                "labels": optional(labels, type: "array"),
                "priority": optional(priority, type: "integer", extra: ["description": "0 (none) to 4 (low)"]),
                "assignee": optional(assignee, type: "object", extra: ["properties": emptyProperties]),
                "assignee_ids": ids,
            ] as [String: Any],
            "required": ["title"],
        ])
    }

    /// A zod tool as MCP servers and the AI SDK send it: a root `$schema`,
    /// value limits and a `format`.
    static var readZod: [String: Any] {
        let filePath: [String: Any] = ["type": "string", "minLength": 1]
        let limit: [String: Any] = ["type": "integer", "exclusiveMinimum": 0, "maximum": 2000]
        let url: [String: Any] = ["type": "string", "format": "uri"]
        return tool("read", [
            "$schema": "http://json-schema.org/draft-07/schema#",
            "type": "object",
            "properties": ["filePath": filePath, "limit": limit, "url": url] as [String: Any],
            "required": ["filePath"],
            "additionalProperties": false,
        ])
    }

    static func prepared(tools: [[String: Any]] = [F.weather, F.time]) throws -> ToolChoicePromptPolicy.Prepared {
        try ToolChoicePromptPolicy.prepare(F.request(choice: "auto", tools: tools), modelType: "gpt_oss")
    }

    static func constraint(tools: [[String: Any]] = [F.weather, F.time], tokenizer: T = T(),
                           maxTokens: Int = 4_096, widens: Bool = true) throws -> GPTOSSAutoToolConstraint {
        let prepared = try prepared(tools: tools)
        let rendered = try #require(prepared.tools)
        return try GPTOSSAutoToolConstraint(names: rendered.map(\.function.name),
            arguments: GPTOSSAutoToolGrammar.compiledArguments(declared: declared(tools), rendered: rendered,
                                                               widens: widens),
            framing: GPTOSSHarmonyFraming(tokenizer: tokenizer, names: [], firstAddedTokenID: 199998),
            vocabulary: F.vocabulary(), maxTokens: maxTokens)
    }

    /// Each tool's compiled arguments, from the body's declarations and the
    /// prompt's rendering.
    static func arguments(tools: [[String: Any]], widens: Bool) throws -> [CompiledToolSchema?] {
        let rendered = try #require(try prepared(tools: tools).tools)
        return GPTOSSAutoToolGrammar.compiledArguments(declared: try declared(tools), rendered: rendered,
                                                       widens: widens)
    }

    /// The tools as the body declares them, before ingress normalization
    /// (`Prepared.declaredTools`).
    static func declared(_ tools: [[String: Any]]) throws -> [OpenAITool] {
        try JSONDecoder().decode([OpenAITool].self, from: JSONSerialization.data(withJSONObject: tools))
    }

    /// Feeds `text` as the sampler would: each token must be allowed at its
    /// budget before it is confirmed. The final state (-1 after a stop), or
    /// nil at the first token refused.
    static func walk(_ text: String, _ constraint: any CBv2TokenConstraint, from initial: Int = 0,
                     consumed: Int = 0) -> Int? {
        walk(T.tokens(text), constraint, from: initial, consumed: consumed)
    }

    static func walk(_ tokens: [Int], _ constraint: any CBv2TokenConstraint, from initial: Int = 0,
                     consumed: Int = 0, visit: (Int, Int) -> Void = { _, _ in }) -> Int? {
        var state = initial
        for (offset, token) in tokens.enumerated() {
            let remaining = constraint.maxTokens - consumed - offset
            visit(state, remaining)
            guard state >= 0, constraint.allowedTokenIDs(state: state, remainingTokens: remaining).contains(token),
                  let next = constraint.nextState(state: state, tokenID: token) else { return nil }
            state = next
        }
        return state
    }

    /// The prompt's open header written as the recipient-first shape.
    static func callFirst(_ name: String, _ arguments: String) -> String {
        " to=functions.\(name)<|channel|>commentary json<|message|>" + arguments
    }

    static let vocabularySize = JSONAnswerProfile.gptOSS.vocabularySize
}

@Suite("GPT-OSS auto tool calls")
struct GPTOSSAutoToolCallTests {
    private typealias A = GPTOSSAutoFixture
    private typealias F = GPTOSSForcedFixture
    private typealias T = HarmonyByteTestTokenizer

    // MARK: - The automaton

    @Test("both Harmony call headers lead to the declared function's arguments, then <|call|>")
    func bothHeaderShapes() throws {
        let constraint = try A.constraint()
        #expect(constraint.mode == .auto)
        let outputs = [
            // The channel first, the recipient after it, after reasoning.
            F.analysis("Paris weather.") + F.call("get_weather", #"{"city":"Paris"}"#),
            // The recipient first, right at the prompt's open header.
            A.callFirst("get_time", #"{"timezone":"CET"}"#),
            // The recipient first after reasoning, with a space before the JSON.
            F.analysis("Time.") + "<|start|>assistant" + A.callFirst("get_time", #" {"timezone":"UTC"} "#),
            // `<|constrain|>` straight after the name, and no content type at all.
            "<|channel|>commentary to=functions.get_weather<|constrain|>json<|message|>{\"city\":\"Rome\"}",
            "<|channel|>commentary to=functions.get_weather<|message|>{\"city\":\"Oslo\"}",
        ]
        for output in outputs {
            let state = try #require(A.walk(output, constraint), "\(output)")
            #expect(constraint.allowedTokenIDs(state: state, remainingTokens: 100).contains(T.call), "\(output)")
            #expect(constraint.nextState(state: state, tokenID: T.call) == -1, "\(output)")
        }
    }

    @Test("a name that prefixes another stays open until a terminator decides it")
    func namePrefixAmbiguity() throws {
        let any = ["type": "object", "properties": ["q": ["type": "string"]]] as [String: Any]
        let constraint = try A.constraint(tools: [A.tool("get", any), A.tool("get_weather", any)])
        let named = try #require(A.walk(F.analysis("x") + "<|start|>assistant<|channel|>commentary to=functions.get",
            constraint))
        let allowed = constraint.allowedTokenIDs(state: named, remainingTokens: 100)
        // `_` continues to get_weather; a space or a header token ends `get`.
        for token in [Int(UInt8(ascii: "_")), Int(UInt8(ascii: " ")), T.constrain, T.message, T.channel] {
            #expect(allowed.contains(token), "\(token)")
        }
        #expect(!allowed.contains(Int(UInt8(ascii: "s"))))
        #expect(!allowed.contains(T.call) && !allowed.contains(T.returnToken) && !allowed.contains(T.end))
        for (name, arguments) in [("get", #"{"q":"a"}"#), ("get_weather", #"{"q":"b"}"#)] {
            let state = try #require(A.walk(F.analysis("x") + F.call(name, arguments), constraint), "\(name)")
            #expect(constraint.nextState(state: state, tokenID: T.call) == -1, "\(name)")
        }
        #expect(A.walk(F.analysis("x") + F.call("get_", "{}"), constraint) == nil)
        #expect(A.walk(F.analysis("x") + F.call("gets", "{}"), constraint) == nil)
        // After `<|channel|>` the parser reads a name only before `commentary`.
        #expect(A.walk(" to=functions.get<|channel|>analysis<|message|>{}", constraint) == nil)
    }

    @Test("an undeclared function cannot be named")
    func undeclaredNameIsImpossible() throws {
        let constraint = try A.constraint()
        for output in [
            F.analysis("x") + F.call("delete_everything", #"{"path":"/"}"#),
            A.callFirst("get_stock", "{}"),
            F.analysis("x") + F.call("get_weathers", "{}"),
            F.analysis("x") + F.call("", "{}"),
        ] {
            #expect(A.walk(output, constraint) == nil, "\(output)")
        }
        let open = try #require(A.walk(" to=functions.", constraint))
        #expect(constraint.allowedTokenIDs(state: open, remainingTokens: 100) == [Int(UInt8(ascii: "g"))])
    }

    @Test("arguments outside the schema cannot be generated, and <|call|> waits for a complete object")
    func argumentsFollowTheSchema() throws {
        let constraint = try A.constraint()
        let header = try #require(A.walk(F.analysis("ok") + F.call("get_weather", ""), constraint))
        #expect(!constraint.allowedTokenIDs(state: header, remainingTokens: 100).contains(T.call))
        for invalid in [#"{"city":1"#, #"{"country":"FR""#, #"{"city":"Paris","unit":"kelvin""#, "[", #""Paris""#,
                        #"{"city":"Paris","city""#, #"{"city":"<|call|>"#, #"{"city":"<|end|>"#] {
            #expect(A.walk(invalid, constraint, from: header) == nil, "\(invalid)")
        }
        let missing = try #require(A.walk(#"{"unit":"f""#, constraint, from: header))
        #expect(A.walk("}", constraint, from: missing) == nil)
        let open = try #require(A.walk(#"{"city":"Paris""#, constraint, from: header))
        #expect(!constraint.allowedTokenIDs(state: open, remainingTokens: 100).contains(T.call))
        #expect(constraint.nextState(state: open, tokenID: T.call) == nil)
        let complete = try #require(A.walk("}", constraint, from: open))
        #expect(constraint.allowedTokenIDs(state: complete, remainingTokens: 100).contains(T.call))
        // The rest of a call header spells no Harmony marker and ends nothing.
        let rest = try #require(A.walk(F.analysis("ok") + "<|start|>assistant<|channel|>commentary to=functions.get_weather ",
            constraint))
        let restAllowed = constraint.allowedTokenIDs(state: rest, remainingTokens: 100)
        for token in [T.call, T.returnToken, T.endOfText, T.start, T.end] { #expect(!restAllowed.contains(token)) }
        let spelled = try #require(A.walk("<|end|", constraint, from: rest))
        #expect(!constraint.allowedTokenIDs(state: spelled, remainingTokens: 100).contains(Int(UInt8(ascii: ">"))))
    }

    @Test("a function whose schema is outside the subset keeps free arguments; its name is still constrained")
    func schemaOutsideTheSubsetFailsOpenPerTool() throws {
        let constraint = try A.constraint(tools: [F.weather, A.search])
        #expect(constraint.constrainsArguments(of: "get_weather"))
        #expect(!constraint.constrainsArguments(of: "search"))
        let header = try #require(A.walk(F.analysis("x") + F.call("search", ""), constraint))
        #expect(constraint.allowedTokenIDs(state: header, remainingTokens: 100).count == A.vocabularySize)
        let free = try #require(A.walk(#"{"query": 42, not json"#, constraint, from: header))
        #expect(constraint.nextState(state: free, tokenID: T.call) == -1)
        // The other function keeps its schema in the same request.
        let weather = try #require(A.walk(F.analysis("x") + F.call("get_weather", ""), constraint))
        #expect(A.walk(#"{"city":1"#, constraint, from: weather) == nil)
        #expect(A.walk(F.analysis("x") + F.call("searching", "{}"), constraint) == nil)
    }

    @Test("reasoning, preambles, answers and other recipients are free: every id is admitted")
    func freeSpansAreUnconstrained() throws {
        let constraint = try A.constraint()
        let outputs = [
            F.analysis("The user greets. No tool to=functions is needed: ok.")
                + "<|start|>assistant<|channel|>final<|message|>Hello! to=functions.x <|end|> {\"a\":1}<|return|>",
            "<|channel|>commentary<|message|>Checking the weather.<|end|>"
                + "<|start|>assistant<|channel|>final<|message|>Sunny.<|return|>",
            "<|channel|>analysis to=browser.search<|message|>x<|end|><|start|>assistant to=python<|channel|>"
                + "commentary<|message|>print(1)<|call|>",
        ]
        for output in outputs {
            var visited = 0
            let final = A.walk(T.tokens(output), constraint) { state, remaining in
                visited += 1
                #expect(constraint.allowedTokenIDs(state: state, remainingTokens: remaining).count == A.vocabularySize)
                #expect(constraint.maskCacheKey(state: state, remainingTokens: remaining)
                    == GPTOSSAutoToolConstraint.freeMaskKey)
            }
            #expect(final == -1, "\(output)")
            #expect(visited == T.tokens(output).count)
        }
        // Any stop ends a free span, as without the grammar.
        let body = try #require(A.walk("<|channel|>final<|message|>Hi", constraint))
        for stop in [T.call, T.returnToken, T.endOfText] { #expect(constraint.nextState(state: body, tokenID: stop) == -1) }
    }

    @Test("masks do not depend on the budget; nothing is reserved or forced near it")
    func budgetReservesNothing() throws {
        let constraint = try A.constraint(maxTokens: 200)
        let body = try #require(A.walk("<|channel|>analysis<|message|>long", constraint))
        let header = try #require(A.walk(F.analysis("x") + F.call("get_weather", #"{"ci"#), constraint))
        for state in [0, body, header] {
            let wide = constraint.allowedTokenIDs(state: state, remainingTokens: 200)
            #expect(constraint.allowedTokenIDs(state: state, remainingTokens: 1) == wide)
            #expect(constraint.maskCacheKey(state: state, remainingTokens: 1)
                == constraint.maskCacheKey(state: state, remainingTokens: 200))
            #expect(constraint.allowedTokenIDs(state: state, remainingTokens: 0) == [])
            #expect(constraint.maskCacheKey(state: state, remainingTokens: 0) == nil)
        }
        // A call the budget cuts is never closed: `<|call|>` still waits for the object.
        #expect(!constraint.allowedTokenIDs(state: header, remainingTokens: 1).contains(T.call))
        #expect(constraint.allowsChainedDecode)
    }

    @Test("asking for a mask interns nothing, so chained decode stays exact")
    func masksArePure() throws {
        let constraint = try A.constraint()
        let header = try #require(A.walk(F.analysis("x") + "<|start|>assistant<|channel|>commentary to=functions.get_w",
            constraint))
        let before = constraint.cachedStateCount
        let first = constraint.allowedTokenIDs(state: header, remainingTokens: 10)
        _ = constraint.allowedTokenIDs(state: 0, remainingTokens: 10)
        #expect(constraint.allowedTokenIDs(state: header, remainingTokens: 9) == first)
        #expect(constraint.cachedStateCount == before)
        #expect(first == [Int(UInt8(ascii: "e"))])
    }

    @Test("the loop guard's exit sequence returns the grammar to a new assistant header")
    func exitThinkingSequenceIsAccepted() throws {
        let constraint = try A.constraint()
        let looping = try #require(A.walk("<|channel|>analysis<|message|>again and again and again", constraint))
        let exit = GenerationLoopExitThinkingPolicy.harmonyAnalysis
        // The exit appends `<|end|><|start|>assistant`: the state the request's own prompt leaves.
        #expect(A.walk("\(exit.close)\(exit.after)", constraint, from: looping) == constraint.initialState)
        // The continuation is its own engine request: the same grammar under its budget.
        let continuation = try constraint.withMaxTokens(321)
        #expect(continuation.maxTokens == 321 && continuation.names == constraint.names)
        let called = try #require(A.walk(A.callFirst("get_weather", #"{"city":"Lyon"}"#), continuation))
        #expect(continuation.nextState(state: called, tokenID: T.call) == -1)
        #expect(A.walk(A.callFirst("get_stock", "{}"), continuation) == nil)
    }

    @Test("a tool whose prompt shows the referenced objects has its arguments held to them")
    func inlinedRefsAreConstrained() throws {
        // The coordinator or the local API inlined the references: the prompt
        // and the grammar agree.
        let constraint = try A.constraint(tools: [A.bookInlined])
        #expect(constraint.constrainsArguments(of: "book"))
        let header = try #require(A.walk(A.callFirst("book", ""), constraint))
        let valid = try #require(A.walk(#"{"passengers":[{"name":"Ada"}]}"#, constraint, from: header))
        #expect(constraint.nextState(state: valid, tokenID: T.call) == -1)
        #expect(A.walk(#"{"passengers":["Ada"]"#, constraint, from: header) == nil)
        // Declared with `$ref`s but rendered inlined: compiled from the
        // declaration with its references inlined.
        let prepared = try A.prepared(tools: [A.bookInlined])
        let arguments = GPTOSSAutoToolGrammar.compiledArguments(declared: try A.declared([A.book]),
            rendered: try #require(prepared.tools))
        #expect(arguments.count == 1 && arguments[0] != nil)
    }

    @Test("a tool whose prompt still shows a $ref keeps free arguments; its name is still constrained")
    func renderedRefsKeepFreeArguments() throws {
        // The legacy repair renders a `$ref` item as a string (`string[]` in
        // the prompt). Holding the arguments to the referenced object would
        // contradict the prompt, so they stay as generated.
        let constraint = try A.constraint(tools: [A.book])
        #expect(!constraint.constrainsArguments(of: "book"))
        let header = try #require(A.walk(A.callFirst("book", ""), constraint))
        #expect(A.walk(#"{"passengers":["Ada"]}"#, constraint, from: header) != nil)
        #expect(constraint.maskCacheKey(state: header, remainingTokens: 100) == GPTOSSAutoToolConstraint.freeMaskKey)
        #expect(A.walk(A.callFirst("delete_everything", ""), constraint) == nil)
        // A cycle stays a `$ref`, outside the subset: free arguments, the name still constrained.
        let cyclic = A.tool("tree", ["type": "object", "$defs": ["Node": ["type": "object", "properties": [
            "child": ["$ref": "#/$defs/Node"]]] as [String: Any]], "properties": ["root": ["$ref": "#/$defs/Node"]]])
        #expect(!(try A.constraint(tools: [cyclic]).constrainsArguments(of: "tree")))
    }

    @Test("nullable unions, value limits and a root $schema are held to the schema's structure")
    func widenedSchemasAreConstrained() throws {
        let constraint = try A.constraint(tools: [A.createIssueRouted, A.readZod])
        #expect(constraint.constrainsArguments(of: "create_issue"))
        #expect(constraint.constrainsArguments(of: "read"))
        let issue = try #require(A.walk(A.callFirst("create_issue", ""), constraint))
        // Labels are objects or null, never bare strings; the priority an integer or null.
        for invalid in [#"{"title":"Crash","labels":[""#, #"{"title":"Crash","priority":"1"#,
                        #"{"title":"Crash","assignee":{"name""#, #"{"labels":null}"#, #"{"title":1"#] {
            #expect(A.walk(invalid, constraint, from: issue) == nil, "\(invalid)")
        }
        for valid in [
            #"{"title":"Crash","labels":[{"name":"bug"},{"name":"ui","color":null}],"priority":1,"assignee_ids":[42,7]}"#,
            #"{"title":"Crash","labels":null,"priority":null,"assignee":{"id":3},"assignee_ids":null}"#,
            #"{"title":"Crash","assignee":null}"#,
        ] {
            let state = try #require(A.walk(valid, constraint, from: issue), "\(valid)")
            #expect(constraint.nextState(state: state, tokenID: T.call) == -1, "\(valid)")
        }
        let read = try #require(A.walk(A.callFirst("read", ""), constraint))
        #expect(A.walk(#"{"filePath":1"#, constraint, from: read) == nil)
        #expect(A.walk(#"{"filePath":"a","offset""#, constraint, from: read) == nil)
        // A limit the grammar cannot spell is the model's: the structure still holds.
        let limits = try #require(A.walk(#"{"filePath":"","limit":5000,"url":"x"}"#, constraint, from: read))
        #expect(constraint.nextState(state: limits, tokenID: T.call) == -1)
    }

    @Test("with the widen switch off, a schema outside the subset as written keeps free arguments")
    func widenSwitchOffKeepsFreeArguments() throws {
        let tools = [A.createIssueRouted, A.readZod, F.weather]
        #expect(try A.arguments(tools: tools, widens: false).map { $0 != nil } == [false, false, true])
        #expect(try A.arguments(tools: tools, widens: true).map { $0 != nil } == [true, true, true])
        // A wider union and an allow-all value stay outside the subset either way.
        let branches: [[String: Any]] = [["type": "string"], ["type": "integer"], ["type": "null"]]
        let union: [String: Any] = ["anyOf": branches]
        let allowAll: [String: Any] = [:]
        let wider = A.tool("pick", ["type": "object", "properties": ["v": union] as [String: Any]])
        let any = A.tool("set", ["type": "object", "properties": ["v": allowAll] as [String: Any]])
        #expect(try A.arguments(tools: [wider, any, A.search], widens: true).allSatisfy { $0 == nil })
    }

    @Test("the render repair beside a nullable union is dropped; other unions keep their keys")
    func unionRepairIsDropped() throws {
        func value(_ json: String) throws -> MLXLMCommon.JSONValue {
            try JSONDecoder().decode(MLXLMCommon.JSONValue.self, from: Data(json.utf8))
        }
        let branches = #"[{"type":"object","properties":{"id":{"type":"integer"}}},{"type":"null"}]"#
        let routed = try value(#"{"anyOf":\#(branches),"type":"object","nullable":true,"properties":{},"description":"who"}"#)
        let written = try value(#"{"anyOf":\#(branches),"description":"who"}"#)
        #expect(GPTOSSAutoToolGrammar.withoutUnionRepair(routed, depth: 0, unwraps: 0) == written)
        let nested = MLXLMCommon.JSONValue.object(["type": .string("object"), "properties": .object(["a": routed])])
        #expect(GPTOSSAutoToolGrammar.withoutUnionRepair(nested, depth: 0, unwraps: 0)
            == .object(["type": .string("object"), "properties": .object(["a": written])]))
        let union = MLXLMCommon.JSONValue.object(["type": .string("string"), "anyOf": .array([
            .object(["type": .string("string")]), .object(["type": .string("integer")])])])
        #expect(GPTOSSAutoToolGrammar.withoutUnionRepair(union, depth: 0, unwraps: 0) == union)
        // The caller's own type is the only one the other branch has: kept.
        let untyped = try value(#"{"type":"integer","anyOf":[{"minimum":1},{"type":"null"}]}"#)
        #expect(GPTOSSAutoToolGrammar.withoutUnionRepair(untyped, depth: 0, unwraps: 0) == untyped)
    }

    @Test("a widened node that states no type keeps free arguments instead of reading as a string")
    func untypedWidenedNodesStayFree() throws {
        // Local declarations, as the body sends them: Pydantic's `Optional[Any]`,
        // a type stated only beside the union, and a limit on an untyped node.
        // Each accepts values a string-typed node would refuse.
        let tools = [
            A.tool("put", try A.parameters(#"{"type":"object","properties":{"value":{"anyOf":[{},{"type":"null"}],"default":null}}}"#)),
            A.tool("take", try A.parameters(#"{"type":"object","properties":{"n":{"type":"integer","anyOf":[{"minimum":1},{"type":"null"}]}},"required":["n"]}"#)),
            A.tool("count", try A.parameters(#"{"type":"object","properties":{"count":{"description":"How many","minimum":1}}}"#)),
            // `properties` alone asserts no type: the caller's `integer` beside the union stays.
            A.tool("pick", try A.parameters(#"{"type":"object","properties":{"n":{"type":"integer","anyOf":[{"properties":{"a":{"type":"string"}}},{"type":"null"}]}},"required":["n"]}"#)),
        ]
        #expect(try A.arguments(tools: tools, widens: true).map { $0 == nil } == [true, true, true, true])
    }

    @Test("nullable unions nested ten deep are still widened")
    func deepNullableUnionsAreWidened() throws {
        // Ten levels of `Optional[Node]` in the routed form: the depth counts
        // levels as the compiler does, not the unions entered on the way.
        var node = #"{"type":"string"}"#
        for _ in 0..<10 {
            node = #"{"anyOf":[{"type":"object","properties":{"next":\#(node)}},{"type":"null"}],"type":"object","nullable":true,"properties":{}}"#
        }
        let parameters = try A.parameters(#"{"type":"object","properties":{"root":\#(node)}}"#)
        let constraint = try A.constraint(tools: [A.tool("chain", parameters)])
        #expect(constraint.constrainsArguments(of: "chain"))
        #expect(!(try A.constraint(tools: [A.tool("chain", parameters)], widens: false).constrainsArguments(of: "chain")))
    }

    @Test("the constraint refuses names and budgets it cannot hold")
    func refusesWhatItCannotFrame() throws {
        let framing = try GPTOSSHarmonyFraming(tokenizer: T(), names: [], firstAddedTokenID: 199998)
        for (names, budget) in [([String](), 10), (["a b"], 10), (["a", "a"], 10), (["a"], 0)] {
            #expect(throws: ToolConstraintSchemaError.self) {
                try GPTOSSAutoToolConstraint(names: names, arguments: names.map { _ in nil }, framing: framing,
                    vocabulary: F.vocabulary(), maxTokens: budget)
            }
        }
    }

    // MARK: - Admission

    @Test("the switch, its passthrough and its name outside the prefix-cache identity")
    func killSwitch() {
        for value in [nil, "", "on", "1", "true"] { #expect(GPTOSSAutoToolGrammar.isEnabled(value)) }
        for value in ["off", "OFF", "0", "false", "no", " off ", "none", "NONE", "disabled", " Disabled "] {
            #expect(!GPTOSSAutoToolGrammar.isEnabled(value), "\(value)")
        }
        let key = GPTOSSAutoToolGrammar.environmentKey
        #expect(!key.hasPrefix("DARKBLOOM_GPTOSS_") && !key.hasPrefix("DARKBLOOM_QWEN_") && !key.hasPrefix("DARKBLOOM_CBV2_"))
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key))
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "off"])[key] == "off")
        let widen = GPTOSSAutoToolGrammar.widenEnvironmentKey
        #expect(widen == "DARKBLOOM_HARMONY_AUTO_TOOL_WIDEN")
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(widen))
        #expect(LaunchAgent.passthroughEnvironment(from: [widen: "off"])[widen] == "off")
    }

    @Test("only auto GPT-OSS requests with tools on an engine that runs constraints get the grammar")
    func admission() throws {
        let handle = TokenizerHandle(T())
        func make(_ prepared: ToolChoicePromptPolicy.Prepared, modelType: String = "gpt_oss",
                  prompt: [Int]? = T.prompt, runs: Bool = true, enabled: Bool = true,
                  tokenizer: TokenizerHandle = handle, width: Int? = A.vocabularySize) -> GPTOSSAutoToolConstraint? {
            GPTOSSAutoToolGrammar.constraint(prepared: prepared, modelType: modelType, tokenizer: tokenizer,
                maxTokens: 200, stopTokenIDs: T.stops, promptTokens: prompt, runsTokenConstraints: runs,
                logitsWidth: width, enabled: enabled)
        }
        let auto = try A.prepared()
        let built = try #require(make(auto))
        #expect(built.maxTokens == 200 && built.names == [Array("get_weather".utf8), Array("get_time".utf8)])
        // Off, another family, forced or no tools, a cluster pair or a native-tracked
        // engine, and a prompt not at the assistant boundary: served as before.
        #expect(make(auto, enabled: false) == nil)
        #expect(make(auto, modelType: "qwen3_5") == nil)
        #expect(make(try ToolChoicePromptPolicy.prepare(F.request(choice: "required"), modelType: "gpt_oss")) == nil)
        #expect(make(try ToolChoicePromptPolicy.prepare(F.request(choice: "none"), modelType: "gpt_oss")) == nil)
        #expect(make(try A.prepared(tools: [])) == nil)
        #expect(make(auto, runs: false) == nil)
        #expect(make(auto, prompt: T.tokens("<|start|>user<|message|>hi<|end|>")) == nil)
        // A tokenizer that fails the Harmony checks: no constraint at all.
        var missing = T()
        missing.controls.removeAll { $0.0 == "<|constrain|>" }
        #expect(make(auto, tokenizer: TokenizerHandle(missing)) == nil)
    }

    @Test("the grammar is declined unless the model's logits are exactly as wide as the vocabulary")
    func logitsWidthMustMatch() throws {
        let auto = try A.prepared()
        func make(_ width: Int?) -> GPTOSSAutoToolConstraint? {
            GPTOSSAutoToolGrammar.constraint(prepared: auto, modelType: "gpt_oss", tokenizer: TokenizerHandle(T()),
                maxTokens: 200, stopTokenIDs: T.stops, promptTokens: T.prompt, runsTokenConstraints: true,
                logitsWidth: width, enabled: true)
        }
        #expect(make(A.vocabularySize) != nil)
        // A free mask admits every id below the vocabulary's size; narrower
        // logits would make it an impossible state at the first step.
        for width in [nil, A.vocabularySize - 1, A.vocabularySize + 1, 200_064] as [Int?] {
            #expect(make(width) == nil, "\(String(describing: width))")
        }
    }

    @Test("the vocabulary-only masks are built once per vocabulary")
    func vocabularyMasksAreShared() throws {
        let vocabulary = try F.vocabulary()
        let first = GPTOSSAutoToolConstraint.vocabularyMasks(for: vocabulary)
        #expect(GPTOSSAutoToolConstraint.vocabularyMasks(for: vocabulary) === first)
        #expect(first.allTokenIDs == Array(0..<vocabulary.pieces.count))
        #expect(first.recipientSensitive == vocabulary.pieceTokenIDs.filter { vocabulary.pieces[$0].contains(0x2E) })
        let other = try F.vocabulary()
        #expect(GPTOSSAutoToolConstraint.vocabularyMasks(for: other) !== first)
    }

    @Test("the loop guard stays on for the grammar's free spans, with its exit")
    func loopGuardKeepsWorking() throws {
        let request = try F.request(choice: "auto")
        let prepared = try A.prepared()
        let exit = GenerationLoopExitThinking(openMarker: "<|channel|>analysis", closeMarker: "<|end|>",
            exitTokens: [T.end, T.start], exitText: "<|end|><|start|>assistant", startsInside: false,
            record: GenerationLoopExitRecord())
        let guarded = GenerationLoopGuardPolicy.resolve(modelType: "gpt_oss", request: request, prepared: prepared,
            tokenConstraint: try A.constraint(), setting: .modelTypes(["gpt_oss"]), exitThinking: exit)
        #expect(guarded != nil)
        #expect(guarded?.exitThinking != nil)
        // Forced calls keep the guard off, as before.
        let forced = try ToolChoicePromptPolicy.prepare(F.request(choice: "required"), modelType: "gpt_oss")
        #expect(GenerationLoopGuardPolicy.resolve(modelType: "gpt_oss", request: request, prepared: forced,
            tokenConstraint: try F.constraint("required"), setting: .modelTypes(["gpt_oss"])) == nil)
    }

    @Test("the local API inlines every GPT-OSS build's references only while the grammar is on")
    func localRefDefault() {
        let on = ToolSchemaRefPolicy(rules: ToolSchemaRefPolicy.defaultRules(gptOSSAutoToolGrammar: true))
        let off = ToolSchemaRefPolicy(rules: ToolSchemaRefPolicy.defaultRules(gptOSSAutoToolGrammar: false))
        for model in ["gpt-oss-20b", "gpt-oss-120b", "mlx-community/gpt-oss-120b-MXFP4-Q8", "GPT-OSS-20B"] {
            #expect(on.mode(forModel: model, modelType: "gpt_oss") == .inline, "\(model)")
            #expect(off.mode(forModel: model, modelType: "gpt_oss") == .off, "\(model)")
        }
        #expect(on.mode(forModel: "gemma-4-26b-qat-4bit", modelType: "gemma4") == .inline)
        #expect(off.rules == [.init(pattern: "gemma-4-26b", mode: .inline), .init(pattern: "qwen3.8-27b", mode: .inline)])
    }
}
