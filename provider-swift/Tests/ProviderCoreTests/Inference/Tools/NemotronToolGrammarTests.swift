import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

/// RED CONTROL (today's API only): Nemotron 3.5 Lightning's `auto` calls under the call grammar: every tool,
/// `strict` or not, the `<tool_call>` frame and the bare `<function=` frame
/// its parser also reads.
enum NemotronToolFixture {
    static let model = "nvidia-nemotron-3.5-lightning"
    static let stops: Set<Int> = [2, 11]
    static let imEnd = 11
    static let handle = TokenizerHandle(NemotronByteTestTokenizer())

    /// A computer-use tool (an action enum, a bounded integer pair, free text)
    /// and a coding tool with a Pydantic-style optional and a URI format, none
    /// of them `strict`.
    static let tools = #"""
    [{"type":"function","function":{"name":"computer","parameters":{"type":"object",
      "properties":{
        "action":{"type":"string","enum":["key","type","left_click","double_click","scroll","screenshot"]},
        "coordinate":{"type":"array","items":{"type":"integer"},"minItems":2,"maxItems":2},
        "text":{"type":"string"},
        "scroll_direction":{"type":"string","enum":["up","down"]}},
      "required":["action"],"additionalProperties":false}}},
     {"type":"function","function":{"name":"bash","parameters":{"type":"object",
      "properties":{
        "command":{"type":"string"},
        "timeout":{"anyOf":[{"type":"integer","minimum":1},{"type":"null"}],"default":null},
        "url":{"type":"string","format":"uri"}},
      "required":["command"],"additionalProperties":false}}}]
    """#

    static func body(model: String = model, tools: String = tools, parallel: Bool? = nil) -> String {
        var body = #"{"model":"\#(model)","messages":[{"role":"user","content":"hi"}],"max_tokens":512,"tools":"#
            + tools
        if let parallel { body += #","parallel_tool_calls":\#(parallel)"# }
        return body + "}"
    }

    static func prepared(_ body: String) throws -> (OpenAIChatCompletionRequest, ToolChoicePromptPolicy.Prepared) {
        let raw = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: Data(body.utf8))
        let request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self,
            from: ToolSchemaNormalization.ensureParameterTypes(in: Data(body.utf8)))
        var prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "nemotron_h")
        prepared.declaredTools = raw.tools
        return (request, prepared)
    }

    static func constraint(_ body: String, thinking: Bool = false, modelType: String = "nemotron_h",
                           parser: ToolCallFormat = .nemotron) throws
        -> QwenStrictToolConstraint? {
        let (request, prepared) = try prepared(body)
        return QwenStrictToolGrammar.constraint(prepared: prepared, request: request, parser: parser,
            tokenizer: handle, modelType: modelType, defaultMaxTokens: 512, stopTokenIDs: stops,
            promptTokens: NemotronByteTestTokenizer.tokens(NemotronByteTestTokenizer.prompt(thinking: thinking)),
            runsTokenConstraints: true)
    }

    static func walk(_ text: String, _ constraint: QwenStrictToolConstraint, from state: Int? = nil) -> Int? {
        var state = state ?? constraint.initialState
        for token in NemotronByteTestTokenizer.tokens(text) {
            guard constraint.allowedTokenIDs(state: state, remainingTokens: 1_000).maskContains(token),
                  let next = constraint.nextState(state: state, tokenID: token) else { return nil }
            state = next
        }
        return state
    }

    static func allows(_ text: String, _ constraint: QwenStrictToolConstraint, after prefix: String) -> Bool {
        guard let state = walk(prefix, constraint) else { return false }
        return walk(text, constraint, from: state) != nil
    }

    /// The calls Lightning's production parser reads from `content`.
    static func calls(_ content: String, _ body: String) throws -> [ToolCall] {
        let (request, prepared) = try prepared(body)
        let handler = try #require(try ToolStreamPreparation.makeHandler(
            request: request, prepared: prepared, modelType: "nemotron_h", streamToolCalls: false))
        _ = handler.processChunk(content)
        return handler.finish()
    }
}

@Suite("Call grammar: Nemotron 3.5 Lightning auto calls")
struct NemotronToolGrammarTests {
    private typealias F = NemotronToolFixture

    @Test func aValidCallWalksAndParsesToItsArguments() throws {
        let body = F.body()
        let constraint = try #require(try F.constraint(body))
        let call = "<tool_call>\n<function=computer>\n<parameter=action>\nscroll\n</parameter>\n"
            + "<parameter=scroll_direction>\ndown\n</parameter>\n</function>\n</tool_call>\n"
        let end = try #require(F.walk(call, constraint))
        #expect(constraint.nextState(state: end, tokenID: F.imEnd) == -1)
        let calls = try F.calls(call, body)
        #expect(calls.count == 1 && calls[0].function.name == "computer")
        #expect(calls[0].function.arguments["action"] == .string("scroll"))
        #expect(calls[0].function.arguments["scroll_direction"] == .string("down"))
    }

    @Test func anInventedEnumValueAnUndeclaredParameterOrNameIsRefused() throws {
        let constraint = try #require(try F.constraint(F.body()))
        let call = "<tool_call>\n<function=computer>\n"
        #expect(!F.allows("<parameter=action>\nscroll_down\n", constraint, after: call))
        #expect(!F.allows("<parameter=action>\ndrag_to\n", constraint, after: call))
        #expect(!F.allows("<parameter=to_coordinate>\n", constraint, after: call))
        #expect(!F.allows("<tool_call>\n<function=click>\n", constraint, after: ""))
        // A required parameter comes before the close.
        #expect(!F.allows("</function>", constraint, after: call))
    }

    @Test func aParameterTheSubsetCannotHoldIsFreeTextAndTheToolIsStillHeld() throws {
        // `bash` has a bounded union and a `format`: the tool compiles one parameter at a time.
        let body = F.body()
        let constraint = try #require(try F.constraint(body))
        let call = "<tool_call>\n<function=bash>\n<parameter=command>\nmake build\n</parameter>\n"
        #expect(F.allows("<parameter=timeout>\n300\n</parameter>\n</function>\n</tool_call>", constraint, after: call))
        #expect(F.allows("<parameter=url>\nhttps://example.com/x\n</parameter>\n", constraint, after: call))
        #expect(!F.allows("<parameter=workdir>\n", constraint, after: call))
        let calls = try F.calls(call + "<parameter=timeout>\n300\n</parameter>\n</function>\n</tool_call>", body)
        #expect(calls.first?.function.arguments["timeout"] == .int(300))
        // The pair of integers compiles: a string where the array goes is refused.
        let computer = "<tool_call>\n<function=computer>\n<parameter=action>\nleft_click\n</parameter>\n"
        #expect(F.allows("<parameter=coordinate>\n[640, 24]\n</parameter>\n", constraint, after: computer))
        #expect(!F.allows("<parameter=coordinate>\n\"640,24\"", constraint, after: computer))
    }

    @Test func aBareFunctionFrameIsHeldAndClosesWithItsOwnTag() throws {
        let body = F.body()
        let constraint = try #require(try F.constraint(body))
        #expect(!F.allows("<function=computer>\n<parameter=action>\nscroll_down", constraint, after: ""))
        let bare = "<function=computer>\n<parameter=action>\nscreenshot\n</parameter>\n</function>"
        let end = try #require(F.walk(bare, constraint))
        #expect(constraint.nextState(state: end, tokenID: F.imEnd) == -1)
        // An undeclared parameter is refused in a bare frame too.
        #expect(!F.allows("<parameter=to_coordinate>\n", constraint, after: "<function=computer>\n"))
        #expect(try F.calls(bare, body).map(\.function.name) == ["computer"])
    }

    @Test func freeTextAndReasoningStayFreeAndNoValueSpellsACallMarker() throws {
        let constraint = try #require(try F.constraint(F.body(), thinking: true))
        // Reasoning may mention any call syntax; text after it may too until a frame opens.
        let thought = "I could call <function=click> or <tool_call>, but first think.</think>"
        let state = try #require(F.walk(thought, constraint))
        #expect(F.walk("Sure: x=1, y=2 and a = b.", constraint, from: state) != nil)
        let text = "<tool_call>\n<function=computer>\n<parameter=action>\ntype\n</parameter>\n<parameter=text>\n"
        #expect(F.allows("a = b, <b>bold</b> stays text\n</parameter>\n", constraint, after: thought + text))
        #expect(!F.allows("see <function=", constraint, after: thought + text))
        #expect(!F.allows("see <tool_call>", constraint, after: thought + text))
    }

    @Test func parallelToolCallsFalseAdmitsOneFrameOfEitherKind() throws {
        let constraint = try #require(try F.constraint(F.body(parallel: false)))
        let one = "<tool_call>\n<function=computer>\n<parameter=action>\nscreenshot\n</parameter>\n</function>\n</tool_call>\n"
        #expect(!F.allows("<tool_call>", constraint, after: one))
        #expect(!F.allows("<function=", constraint, after: one))
    }
}
