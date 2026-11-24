import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// The call parser reads a call's arguments with the caller's declarations
/// (`ToolArgumentSchemas`), not the render types the ingress repair writes for
/// the chat template, while the template keeps rendering the repaired ones.
/// The schemas are the constructs of OpenRouter's tool-call schema fuzz grid
/// (`grid.ts`, `keywords.ts`): leaves, type pairs, unions, nullable wrappers
/// and keyword leaves, each as the `p` parameter of one strict tool.
@Suite("Declared tool arguments")
struct DeclaredToolArgumentTests {
    private static let modelID = "Qwen3.5-9B"
    private static let modelType = "qwen3_5"

    private static let primitives = ["string", "integer", "number", "boolean", "null"]

    /// Every `p` schema of the grid this suite checks, by label.
    private static var constructs: [(label: String, schema: [String: Any])] {
        var rows: [(String, [String: Any])] = []
        for type in primitives {
            rows.append((type, ["type": type]))
            rows.append(("nullable/\(type)", ["anyOf": [["type": type], ["type": "null"]]]))
            rows.append(("nullable-first/\(type)", ["anyOf": [["type": "null"], ["type": type]]]))
            rows.append(("array/\(type)", ["type": "array", "items": ["type": type]]))
            rows.append(("anyOf1/\(type)", ["anyOf": [["type": type]]]))
            rows.append(("anyOf3/\(type)", ["anyOf": [
                ["type": "array", "items": ["type": "string"]], ["type": type], ["type": "object"],
            ]]))
            rows.append(("oneOf3/\(type)", ["oneOf": [
                ["type": "array", "items": ["type": "string"]], ["type": type], ["type": "object"],
            ]]))
        }
        for (a, b) in primitives.flatMap({ a in primitives.filter { $0 != a }.map { (a, $0) } }) {
            rows.append(("type[\(a),\(b)]", ["type": [a, b]]))
            rows.append(("anyOf[\(a),\(b)]", ["anyOf": [["type": a], ["type": b]]]))
            rows.append(("oneOf[\(a),\(b)]", ["oneOf": [["type": a], ["type": b]]]))
        }
        rows += [
            ("enum<string>", ["enum": ["a", "b"]]),
            ("enum<integer>", ["enum": [1, 2, 3]]),
            ("enum<number>", ["enum": [1.5, 2.5]]),
            ("enum<boolean>", ["enum": [true, false]]),
            ("enum<null>", ["enum": [NSNull()]]),
            ("enum<mixed>", ["enum": ["a", 1, true, NSNull()]]),
            ("const<string>", ["const": "a"]),
            ("const<integer>", ["const": 7]),
            ("const<number>", ["const": 2.5]),
            ("const<boolean>", ["const": false]),
            ("const<null>", ["const": NSNull()]),
            ("{}", [:]),
            ("not<string>", ["not": ["type": "string"]]),
            ("if<integer>then{minimum}else<string>", [
                "if": ["type": "integer"], "then": ["type": "integer", "minimum": 3], "else": ["type": "string"],
            ]),
            ("type[object,null]", [
                "type": ["object", "null"], "properties": ["k": ["type": "integer"]], "required": ["k"],
                "additionalProperties": false,
            ]),
            ("type[null,array]", ["type": ["null", "array"], "items": ["type": "integer"]]),
            ("dict", ["type": "object", "additionalProperties": true]),
            ("map{patternProperties}<integer>", [
                "type": "object", "patternProperties": ["^x_": ["type": "integer"]], "additionalProperties": false,
            ]),
            ("map<integer>", ["type": "object", "additionalProperties": ["type": "integer"]]),
            ("array{contains<integer>}", [
                "type": "array", "items": ["type": ["string", "integer"]], "contains": ["type": "integer"],
                "minContains": 1, "maxContains": 2,
            ]),
            ("prefixItems[string,integer,boolean]", [
                "type": "array", "prefixItems": [["type": "string"], ["type": "integer"], ["type": "boolean"]],
            ]),
            ("allOf", ["allOf": [
                ["type": "object", "properties": ["a": ["enum": [1, 2]]], "required": ["a"]],
                ["type": "object", "properties": ["b": ["type": "string"]], "required": ["b"]],
            ]]),
            ("allOf1/enum<integer>", ["allOf": [["enum": [1, 2]]]]),
            ("oneOf3-tagged", ["oneOf": [
                ["type": "object", "properties": ["kind": ["const": "a"], "v": ["type": "string"]],
                 "required": ["kind", "v"]],
                ["type": "object", "properties": ["kind": ["const": "b"], "v": ["enum": [1, 2]]],
                 "required": ["kind", "v"]],
            ]]),
            ("integer{minimum,maximum}", ["type": "integer", "minimum": 0, "maximum": 9]),
            ("string{pattern}", ["type": "string", "pattern": "^a"]),
        ]
        return rows
    }

    /// Instances every construct is checked over.
    private static let instances: [MLXLMCommon.JSONValue] = [
        .null, .bool(true), .bool(false), .int(0), .int(2), .int(7), .int(-3), .double(2.5), .double(1.5),
        .string(""), .string("a"), .string("b"), .string("7"), .string("x"),
        .array([]), .array([.string("a")]), .array([.int(1)]), .array([.string("a"), .int(1)]),
        .array([.string("a"), .int(1), .bool(true)]),
        .object([:]), .object(["k": .int(1)]), .object(["x_a": .int(1)]), .object(["a": .int(1), "b": .string("s")]),
        .object(["kind": .string("b"), "v": .int(2)]), .object(["kind": .string("a"), "v": .string("s")]),
    ]

    private static func json(_ object: Any) throws -> MLXLMCommon.JSONValue {
        try JSONDecoder().decode(
            MLXLMCommon.JSONValue.self, from: JSONSerialization.data(withJSONObject: object, options: .fragmentsAllowed))
    }

    private static func parameters(_ schema: [String: Any]) -> [String: Any] {
        ["type": "object", "properties": ["p": schema], "required": ["p"]]
    }

    private static func body(_ schema: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "model": modelID,
            "messages": [["role": "user", "content": "Probe it."]],
            "tools": [["type": "function", "function": [
                "name": "probe", "strict": true, "parameters": parameters(schema),
            ] as [String: Any]]],
            "tool_choice": "auto",
        ] as [String: Any])
    }

    /// The production ingress (`MultiModelBatchSchedulerEngine`): the
    /// repaired request, and the caller's declarations beside it.
    private static func ingress(_ schema: [String: Any]) throws
        -> (request: OpenAIChatCompletionRequest, prepared: ToolChoicePromptPolicy.Prepared)
    {
        let inbound = try ProviderLoop.decodeInboundChatRequest(body(schema))
        let prepared = try ToolChoicePromptPolicy.prepare(inbound.request, modelType: modelType)
            .withDeclaredTools(inbound.extensions.templateControls.declaredTools, modelType: modelType)
        return (inbound.request, prepared)
    }

    /// Whether the strict `auto` check accepts `value` for `p` under
    /// `parameters`, read as the caller's declaration.
    private static func accepts(
        _ value: MLXLMCommon.JSONValue, parameters: MLXLMCommon.JSONValue,
        prepared: ToolChoicePromptPolicy.Prepared
    ) -> Bool {
        var prepared = prepared
        prepared.declaredTools = [OpenAITool(function: .init(name: "probe", parameters: parameters, strict: true))]
        let call = ToolCall(function: .init(name: "probe", arguments: ["p": value]))
        return (try? ToolConstraintValidation.validate([call], prepared: prepared)) != nil
    }

    private static func property(_ tools: [OpenAITool]?) -> MLXLMCommon.JSONValue? {
        guard case .object(let parameters)? = tools?.first?.function.parameters,
              case .object(let properties)? = parameters["properties"] else { return nil }
        return properties["p"]
    }

    // MARK: - The parser's reading accepts what the declaration accepts

    @Test(arguments: constructs.map(\.label))
    func theReadingAcceptsExactlyTheDeclaredInstances(_ label: String) throws {
        let schema = try #require(Self.constructs.first { $0.label == label }).schema
        let (_, prepared) = try Self.ingress(schema)
        let declared = try Self.json(Self.parameters(schema))
        let reading = ToolArgumentSchemas.typingFiniteValues(declared, depth: 0)
        for instance in Self.instances {
            #expect(Self.accepts(instance, parameters: reading, prepared: prepared)
                == Self.accepts(instance, parameters: declared, prepared: prepared), "\(label): \(instance)")
        }
    }

    @Test(arguments: constructs.map(\.label))
    func theParserReadsTheDeclarationTheTemplateRendersTheRepair(_ label: String) throws {
        let schema = try #require(Self.constructs.first { $0.label == label }).schema
        let (request, prepared) = try Self.ingress(schema)
        // The template still renders a string `type` on the parameter.
        guard case .object(let rendered)? = Self.property(request.tools), case .string? = rendered["type"] else {
            Issue.record("\(label): the rendered parameter has no render type")
            return
        }
        // The parser reads the declaration, typed only where `enum`/`const` say so.
        let expected = ToolArgumentSchemas.typingFiniteValues(try Self.json(schema), depth: 0)
        #expect(Self.property(prepared.argumentTools) == expected, "\(label)")
        #expect(prepared.argumentTools?.map(\.function.name) == prepared.tools?.map(\.function.name))
    }

    @Test func typingOnlyNamesTheTypesOfTheValues() throws {
        let typed = { (schema: [String: Any]) throws -> MLXLMCommon.JSONValue? in
            guard case .object(let object) = ToolArgumentSchemas.typingFiniteValues(try Self.json(schema), depth: 0)
            else { return nil }
            return object["type"]
        }
        #expect(try typed(["enum": [1, 2]]) == .string("integer"))
        #expect(try typed(["enum": [1, 2.5]]) == .string("number"))
        #expect(try typed(["enum": ["a", NSNull()]]) == .array([.string("null"), .string("string")]))
        #expect(try typed(["const": true]) == .string("boolean"))
        #expect(try typed(["enum": [1], "type": "number"]) == .string("number"))
        #expect(try typed(["not": ["type": "string"]]) == nil)
        #expect(try typed(["anyOf": [["type": "integer"], ["type": "string"]]]) == nil)
        // Values are never walked as schemas.
        let constant = try Self.json(["const": ["enum": [1]]])
        #expect(ToolArgumentSchemas.typingFiniteValues(constant, depth: 0)
            == (try Self.json(["const": ["enum": [1]], "type": "object"])))
    }

    /// The strict check accepts what the call parser reads under the schemas
    /// the coordinator forwards (a render type beside a mixed enum, a `not`
    /// of that type, a condition, a union), and a client's own type that
    /// agrees with every branch still holds.
    @Test func theStrictCheckAcceptsWhatTheParserReadsUnderRenderTypes() throws {
        let (_, prepared) = try Self.ingress(["type": "string"])
        let cases: [([String: Any], MLXLMCommon.JSONValue, Bool)] = [
            (["enum": ["default", "inherit", "archive", -1], "type": "string"], .int(-1), true),
            (["enum": ["default", "inherit", "archive", -1], "type": "string"], .string("archive"), true),
            (["enum": ["default", "inherit", "archive", -1], "type": "string"], .int(2), false),
            (["not": ["type": "string"], "type": "string"], .int(-2500), true),
            (["if": ["type": "integer"], "then": ["type": "integer", "minimum": -100_000_000],
              "else": ["type": "string"], "type": "string"], .int(-2500), true),
            (["if": ["type": "integer"], "then": ["type": "integer", "minimum": -100_000_000],
              "else": ["type": "string"], "type": "string"], .int(-200_000_000), false),
            (["anyOf": [["type": "string"], ["type": "integer"]], "type": "string"], .int(-4200), true),
            // A client's own type still holds where no branch is typed otherwise.
            (["type": "string", "not": ["type": "integer"]], .int(5), false),
            (["type": "string", "if": ["minLength": 2], "then": ["pattern": "^a"]], .int(5), false),
        ]
        for (schema, value, accepted) in cases {
            let parameters = try Self.json(Self.parameters(schema))
            #expect(Self.accepts(value, parameters: parameters, prepared: prepared) == accepted, "\(schema) \(value)")
        }
    }

    @Test func glmKeepsReadingItsDeclarationsAsSent() throws {
        let inbound = try ProviderLoop.decodeInboundChatRequest(Self.body(["enum": [1, 2]]))
        let prepared = try ToolChoicePromptPolicy.prepare(inbound.request, modelType: Self.modelType)
            .withDeclaredTools(inbound.extensions.templateControls.declaredTools, modelType: "glm5_next")
        #expect(prepared.argumentTools == nil)
        #expect(prepared.declaredTools != nil)
    }

    // MARK: - Qwen 3.5 calls end to end

    /// A value the model writes for `p`, and the argument it must parse to.
    private static var calls: [(label: String, schema: [String: Any], text: String, parsed: MLXLMCommon.JSONValue)] {
        [
            // The repair reads these unions as their first member, `integer`,
            // and kept "2.5" as text, which the declaration refuses.
            ("oneOf[integer,number]", ["oneOf": [["type": "integer"], ["type": "number"]]], "2.5", .double(2.5)),
            ("anyOf[integer,number]", ["anyOf": [["type": "integer"], ["type": "number"]]], "2.5", .double(2.5)),
            ("type[integer,number]", ["type": ["integer", "number"]], "2.5", .double(2.5)),
            ("nullable/type[integer,number,null]", ["type": ["integer", "number", "null"]], "2.5", .double(2.5)),
            // Unchanged readings.
            ("enum<integer>", ["enum": [1, 2, 3]], "2", .int(2)),
            ("enum<boolean>", ["enum": [true, false]], "false", .bool(false)),
            ("const<integer>", ["const": 7], "7", .int(7)),
            ("allOf1/enum<integer>", ["allOf": [["enum": [1, 2]]]], "2", .int(2)),
            ("type[integer,null]@null", ["type": ["integer", "null"]], "null", .null),
            ("type[integer,null]", ["type": ["integer", "null"]], "42", .int(42)),
            ("nullable-first/integer", ["anyOf": [["type": "null"], ["type": "integer"]]], "5", .int(5)),
            ("type[string,integer]", ["type": ["string", "integer"]], "abc", .string("abc")),
            ("anyOf[integer,string]", ["anyOf": [["type": "integer"], ["type": "string"]]], "abc", .string("abc")),
            ("if<integer>then{minimum}else<string>", [
                "if": ["type": "integer"], "then": ["type": "integer", "minimum": 3], "else": ["type": "string"],
            ], "hello", .string("hello")),
            ("{}", [:], "abc", .string("abc")),
            ("array/integer", ["type": "array", "items": ["type": "integer"]], "[1, 2]", .array([.int(1), .int(2)])),
        ]
    }

    @Test(arguments: calls.map(\.label))
    func aCallParsesToAnArgumentItsDeclarationAccepts(_ label: String) throws {
        let row = try #require(Self.calls.first { $0.label == label })
        let (request, prepared) = try Self.ingress(row.schema)
        let handler = try #require(try ToolStreamPreparation.makeHandler(
            request: request, prepared: prepared, modelType: Self.modelType, streamToolCalls: false))
        let frame = "<tool_call>\n<function=probe>\n<parameter=p>\n\(row.text)\n</parameter>\n</function>\n</tool_call>"
        _ = handler.processChunk(frame)
        let calls = handler.finish()
        #expect(calls.first?.function.arguments["p"] == row.parsed, "\(label)")
        #expect(throws: Never.self, "\(label)") { try ToolConstraintValidation.validate(calls, prepared: prepared) }
    }
}
