import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// The type the ingress repair writes beside a union, a mixed `enum`, a `not`
/// or an `if` is a render hint (`QwenParserLiteralReading.rendersSiblingType`).
/// GPT-OSS's `auto` grammar compiles the declaration without it, so a union's
/// arguments are no longer held to its first branch.
@Suite("GPT-OSS auto tool grammar render hints")
struct GPTOSSAutoToolRenderHintTests {
    private typealias A = GPTOSSAutoFixture
    private typealias F = GPTOSSForcedFixture
    private typealias T = HarmonyByteTestTokenizer

    private static func tool(_ name: String, _ schema: [String: Any]) -> [String: Any] {
        A.tool(name, ["type": "object", "properties": ["v": schema], "required": ["v"]])
    }

    /// Declarations as the coordinator forwards them today: the union kept,
    /// the repair's render type beside it.
    private static var hinted: [String: [String: Any]] {
        [
            "adjust": tool("adjust", [
                "anyOf": [["type": "string"], ["type": "integer"]], "type": "string",
            ]),
            "pick": tool("pick", [
                "oneOf": [["type": "string"], ["type": "integer"]], "type": "string",
            ]),
            "mode": tool("mode", [
                "enum": ["default", "inherit", -1] as [Any], "type": "string",
            ]),
        ]
    }

    private static func accepts(_ constraint: GPTOSSAutoToolConstraint, _ name: String, _ value: String) -> Bool {
        guard let header = A.walk(F.analysis("x") + F.call(name, ""), constraint),
            let state = A.walk("{\"v\":\(value)}", constraint, from: header)
        else { return false }
        return constraint.nextState(state: state, tokenID: T.call) == -1
    }

    @Test("a union with the repair's render type admits each of its branches")
    func hintedUnionsAdmitEveryBranch() throws {
        let tools = Self.hinted
        let constraint = try A.constraint(tools: [tools["adjust"]!, tools["pick"]!])
        for name in ["adjust", "pick"] {
            #expect(Self.accepts(constraint, name, "-4200"), "\(name)")
            #expect(Self.accepts(constraint, name, "\"-4200\""), "\(name)")
        }
    }

    @Test("a mixed enum with the repair's render type admits its non-string member")
    func hintedEnumAdmitsItsMembers() throws {
        let constraint = try A.constraint(tools: [Self.hinted["mode"]!])
        #expect(Self.accepts(constraint, "mode", "-1"))
        #expect(Self.accepts(constraint, "mode", "\"inherit\""))
    }

    /// Declarations without a render hint, which the pre-pass returns as
    /// they are, and Pydantic's nullable unions, whose render type the
    /// widening already drops (`withoutUnionRepair`): their compiled
    /// arguments are exactly those before.
    private static var unchanged: [(tool: [String: Any], identical: Bool)] {
        [
            (F.weather, true), (F.time, true), (A.readZod, true), (A.bookInlined, true), (A.search, true),
            (tool("plain", ["type": "integer"]), true),
            (tool("nullable", ["type": ["integer", "null"]]), true),
            (tool("consistent", [
                "type": "object", "properties": ["a": ["type": "string"]],
                "anyOf": [["required": ["a"]], ["properties": ["a": ["minLength": 1]]]] as [Any],
            ]), true),
            (A.createIssueRouted, false),
        ]
    }

    @Test("a declaration without a render hint compiles exactly as before")
    func unhintedDeclarationsCompileAsBefore() throws {
        for (raw, identical) in Self.unchanged {
            let declared = try A.declared([raw])
            let tool = try #require(declared.first)
            let resolved = GPTOSSAutoToolGrammar.resolvingRefs(tool)
            let before: CompiledToolSchema? =
                (try? ToolConstraintSchemaCompiler.compile(tools: [resolved], mode: .auto).first)
                ?? GPTOSSAutoToolGrammar.widenedArguments(resolved)
            let prepared = try A.prepared(tools: [raw])
            let after = GPTOSSAutoToolGrammar.compiledArguments(
                declared: declared, rendered: try #require(prepared.tools))
            let name = tool.function.name
            if identical {
                #expect(GPTOSSAutoToolGrammar.withoutRenderHintTypes(resolved) == resolved, "\(name)")
            }
            #expect(String(reflecting: after.first ?? nil) == String(reflecting: before), "\(name)")
        }
    }

    @Test("forced choices compile the request's tools as before")
    func forcedChoicesAreUnchanged() throws {
        let tools = Self.hinted
        for raw in [tools["adjust"]!, tools["mode"]!] {
            let request = try F.request(choice: "required", tools: [raw])
            let prepared = try? ToolChoicePromptPolicy.prepare(request, modelType: "gpt_oss")
            let direct = try? ToolConstraintSchemaCompiler.compile(tools: request.tools ?? [], mode: .required)
            #expect(String(reflecting: prepared?.compiledTools) == String(reflecting: direct))
        }
    }
}
