import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

/// Nemotron 3.5 Lightning's `auto` calls under the call grammar: every tool,
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
      "required":["command"],"additionalProperties":false}}},
     {"type":"function","function":{"name":"click","parameters":{"type":"object",
      "properties":{"x":{"type":"integer","minimum":0,"maximum":999},"y":{"type":"integer","minimum":0,"maximum":999}},
      "required":["x","y"],"additionalProperties":false}}}]
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
                           parser: ToolCallFormat = .nemotron, nemotron: Bool = true) throws
        -> QwenStrictToolConstraint? {
        let (request, prepared) = try prepared(body)
        return QwenStrictToolGrammar.constraint(prepared: prepared, request: request, parser: parser,
            tokenizer: handle, modelType: modelType, defaultMaxTokens: 512, stopTokenIDs: stops,
            promptTokens: NemotronByteTestTokenizer.tokens(NemotronByteTestTokenizer.prompt(thinking: thinking)),
            runsTokenConstraints: true, nemotron: nemotron)
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

    @Test func everyLightningBuildHoldsItsAutoCallsAndNoOtherNemotronDoes() throws {
        for model in JSONAnswerFamilyTests.lightningIDs {
            #expect(try F.constraint(F.body(model: model)) != nil, "\(model)")
        }
        for model in ["nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B", "nvidia-nemotron-3.5-super"] {
            #expect(try F.constraint(F.body(model: model)) == nil, "\(model)")
        }
        // The kill switch, and the Qwen parser on a Nemotron build, leave calls free.
        #expect(try F.constraint(F.body(), nemotron: false) == nil)
        #expect(try F.constraint(F.body(), parser: .qwen35) == nil)
        #expect(QwenStrictToolGrammar.nemotron(environment: [:]))
        #expect(!QwenStrictToolGrammar.nemotron(environment: [QwenStrictToolGrammar.nemotronEnvironmentKey: "off"]))
        #expect(QwenStrictToolGrammar.nemotron(environment: [QwenStrictToolGrammar.nemotronEnvironmentKey: "on"]))
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(QwenStrictToolGrammar.nemotronEnvironmentKey))
    }

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
        #expect(!F.allows("<tool_call>\n<function=drag>\n", constraint, after: ""))
        // A required parameter comes before the close.
        #expect(!F.allows("</function>", constraint, after: call))
    }

    @Test func aParameterWithAnAssertionTheSubsetCannotSpellKeepsItsTypeAndTheToolIsStillHeld() throws {
        // `bash` has a bounded union and a `format`, `click` bounded integers: those tools compile one parameter at
        // a time, without the assertion, so each value keeps its type and only the bound is left to the model.
        let body = F.body()
        let constraint = try #require(try F.constraint(body))
        let call = "<tool_call>\n<function=bash>\n<parameter=command>\nmake build\n</parameter>\n"
        #expect(F.allows("<parameter=timeout>\n300\n</parameter>\n</function>\n</tool_call>", constraint, after: call))
        #expect(F.allows("<parameter=timeout>\nnull\n</parameter>\n", constraint, after: call))
        #expect(!F.allows("<parameter=timeout>\n3.5", constraint, after: call))
        #expect(!F.allows("<parameter=timeout>\n\"300\"", constraint, after: call))
        #expect(F.allows("<parameter=url>\nhttps://example.com/x\n</parameter>\n", constraint, after: call))
        #expect(!F.allows("<parameter=workdir>\n", constraint, after: call))
        let click = "<tool_call>\n<function=click>\n<parameter=x>\n"
        #expect(F.allows("78\n</parameter>\n", constraint, after: click))
        #expect(!F.allows("0.078125", constraint, after: click))
        #expect(!F.allows("\"78\"", constraint, after: click))
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

@Suite("Call grammar: Nemotron 3.5 Lightning edge cases")
struct NemotronToolGrammarEdgeTests {
    private typealias F = NemotronToolFixture

    static func tool(_ name: String, _ parameters: String) -> String {
        #"{"type":"function","function":{"name":"\#(name)","parameters":\#(parameters)}}"#
    }

    /// Every token a mask admits has a next state, over `ids` (a sweep), in `state`.
    static func agrees(_ constraint: QwenStrictToolConstraint, _ state: Int, ids: Range<Int>) -> Bool {
        let allowed = constraint.allowedTokenIDs(state: state, remainingTokens: 1_000)
        return ids.allSatisfy { !allowed.maskContains($0) || constraint.nextState(state: state, tokenID: $0) != nil }
    }

    @Test func multiBytePiecesThatCompleteAFunctionOpeningAreSimulatedEverywhere() throws {
        // Pieces that leave a call opening and then complete `<function=` inside themselves.
        let extra: [(String, Int)] = [("x<function=zz", 2000), ("x<function=co", 2001), ("=zz", 2002), ("a=b", 2003),
                                      ("</function>", 2004), ("unction=co", 2005)]
        let tokenizer = NemotronByteTestTokenizer(markers: NemotronByteTestTokenizer.pinned + extra)
        let (request, prepared) = try F.prepared(F.body())
        let constraint = try #require(QwenStrictToolGrammar.constraint(prepared: prepared, request: request,
            parser: .nemotron, tokenizer: TokenizerHandle(tokenizer), modelType: "nemotron_h", defaultMaxTokens: 512,
            stopTokenIDs: F.stops, promptTokens: NemotronByteTestTokenizer.tokens(
                NemotronByteTestTokenizer.prompt(thinking: false)), runsTokenConstraints: true, nemotron: true))
        func state(_ text: String) throws -> Int {
            var state = constraint.initialState
            for token in NemotronByteTestTokenizer.tokens(text) {   // byte pieces only: the extra pieces are not used
                state = try #require(constraint.nextState(state: state, tokenID: token), "\(text)")
            }
            return state
        }
        let prefixes = ["", "<tool_call>", "<tool_call>\n", "<tool_call>\n<", "<tool_call>\n<f", "<tool_call>\n<functio",
                        "<function=", "<function=computer>\n<parameter=text>\nab",
                        "<tool_call>\n<function=computer>\n<parameter=coordinate>\n[1, "]
        for prefix in prefixes {
            #expect(Self.agrees(constraint, try state(prefix), ids: 2000..<2006), "\(prefix.debugDescription)")
            #expect(Self.agrees(constraint, try state(prefix), ids: 1000..<1256), "\(prefix.debugDescription)")
        }
        // In a call opening, a piece that leaves it for text and opens an undeclared bare call is refused.
        let opening = try state("<tool_call>\n<")
        #expect(!constraint.allowedTokenIDs(state: opening, remainingTokens: 1_000).maskContains(2000))
        #expect(constraint.allowedTokenIDs(state: opening, remainingTokens: 1_000).maskContains(2001))
    }

    @Test func aBareFrameValueCannotSpellItsOwnClose() throws {
        let constraint = try #require(try F.constraint(F.body()))
        let text = "<parameter=action>\ntype\n</parameter>\n<parameter=text>\n"
        #expect(!F.allows("a</function>", constraint, after: "<function=computer>\n" + text))
        // The wrapped frame ends at `</tool_call>`, so its values may.
        #expect(F.allows("a</function> b\n</parameter>\n", constraint, after: "<tool_call>\n<function=computer>\n" + text))
    }

    @Test func parallelToolCallsFalseAfterABareFrame() throws {
        let constraint = try #require(try F.constraint(F.body(parallel: false)))
        let one = "<function=computer>\n<parameter=action>\nscreenshot\n</parameter>\n</function>\n"
        #expect(!F.allows("<tool_call>", constraint, after: one))
        #expect(!F.allows("<function=", constraint, after: one))
    }

    @Test func lenientToolsResolveDefsBesideOneParameter() throws {
        let tools = "[" + Self.tool("label", ##"{"type":"object","$defs":{"Label":{"type":"object","properties":{"name":{"type":"string"},"color":{"type":"string","enum":["red","blue"]}},"required":["name"],"additionalProperties":false}},"properties":{"labels":{"type":"array","items":{"$ref":"#/$defs/Label"}},"priority":{"type":"integer","minimum":0,"maximum":4}},"required":["labels"],"additionalProperties":false}"##) + "]"
        let body = F.body(tools: tools)
        let constraint = try #require(try F.constraint(body))
        let call = "<tool_call>\n<function=label>\n<parameter=labels>\n"
        #expect(F.allows(#"[{"name": "bug", "color": "red"}]"# + "\n</parameter>\n</function>\n</tool_call>", constraint, after: call))
        #expect(!F.allows(#"["bug"]"#, constraint, after: call))
        #expect(!F.allows(#"[{"name": "bug", "color": "green"}]"#, constraint, after: call))
        let calls = try F.calls(call + #"[{"name": "bug"}]"# + "\n</parameter>\n</function>\n</tool_call>", body)
        #expect(calls.first?.function.arguments["labels"] == .array([.object(["name": .string("bug")])]))
    }

    @Test func requestsTheGrammarCannotTrackStayUnconstrained() throws {
        let many = (0..<130).map { #""p\#($0)":{"type":"string","format":"uri"}"# }.joined(separator: ",")
        #expect(try F.constraint(F.body(tools: "[" + Self.tool("wide", #"{"type":"object","properties":{\#(many)}}"#) + "]")) == nil)
        #expect(try F.constraint(F.body(tools: "[" + Self.tool("arrow", #"{"type":"object","properties":{"a>b":{"type":"integer","minimum":1}}}"#) + "]")) == nil)
        #expect(try F.constraint(F.body(tools: "[" + Self.tool("list", #"{"type":"array","items":{"type":"string"}}"#) + "]")) == nil)
        // A tool that declares no properties and stays open (kwargs) would take no argument: not held.
        #expect(try F.constraint(F.body(tools: "[" + Self.tool("kwargs", #"{"type":"object"}"#) + "]")) == nil)
        #expect(try F.constraint(F.body(tools: "[" + Self.tool("kwargs", #"{"type":"object","additionalProperties":{"type":"string"}}"#) + "]")) == nil)
        // An empty `properties`, or empty `parameters`, is a tool that takes no arguments; so is an open object root as
        // the coordinator's render repair forwards it (with `"properties": {}`).
        for parameters in [#"{"type":"object","properties":{}}"#, "{}", #"{"type":"object","properties":{},"additionalProperties":true}"#] {
            let none = try #require(try F.constraint(F.body(tools: "[" + Self.tool("status", parameters) + "]")), "\(parameters)")
            #expect(F.allows("</function>\n</tool_call>", none, after: "<tool_call>\n<function=status>\n"))
            #expect(!F.allows("<parameter=", none, after: "<tool_call>\n<function=status>\n"))
        }
    }

    @Test func aJSONStringValueCannotSpellAFunctionOpening() throws {
        let tools = "[" + Self.tool("tag", #"{"type":"object","properties":{"names":{"type":"array","items":{"type":"string"}}},"required":["names"],"additionalProperties":false}"#) + "]"
        let constraint = try #require(try F.constraint(F.body(tools: tools)))
        let call = "<tool_call>\n<function=tag>\n<parameter=names>\n"
        #expect(F.allows(#"["a=b", "<b>"]"#, constraint, after: call))
        #expect(!F.allows(#"["<function="#, constraint, after: call))
    }

    @Test func everyOffWordTurnsTheNemotronGrammarOff() {
        typealias G = QwenStrictToolGrammar
        for word in ["off", "0", "false", "no", "none", "disabled", " OFF "] {
            #expect(!G.nemotron(environment: [G.nemotronEnvironmentKey: word]), "\(word)")
        }
        for word in ["", "on", "1", "true", "yes", "anything"] {
            #expect(G.nemotron(environment: [G.nemotronEnvironmentKey: word]), "\(word)")
        }
    }
}

/// `DARKBLOOM_TEST_NEMOTRON_TOKENIZER_DIR=<Lightning snapshot>`: the shipped
/// tokenizer holds the call markers at the pinned ids, and a call it tokenizes
/// walks the grammar.
@Suite("Call grammar: Nemotron 3.5 Lightning real tokenizer",
       .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_TEST_NEMOTRON_TOKENIZER_DIR"] != nil))
struct NemotronToolGrammarRealTokenizerTests {
    private typealias F = NemotronToolFixture

    @Test func theShippedTokenizerMatchesTheCallContract() async throws {
        let (tokenizer, stops) = try await JSONAnswerRealTokenizerCheck.load("DARKBLOOM_TEST_NEMOTRON_TOKENIZER_DIR")
        #expect(stops == F.stops)
        let vocabulary = try JSONAnswerVocabulary(tokenizer: tokenizer, profile: QwenStrictToolGrammar.nemotronProfile,
                                                  stopTokenIDs: stops)
        #expect(vocabulary.pieceTokenIDs.count == 131_072 - 1_000 + 4)
        let (request, prepared) = try F.prepared(F.body())
        let prompt = try tokenizer.applyChatTemplate(messages: [["role": "user", "content": "Scroll down."]],
            tools: nil, additionalContext: ["enable_thinking": false])
        let constraint = try #require(QwenStrictToolGrammar.constraint(prepared: prepared, request: request,
            parser: .nemotron, tokenizer: TokenizerHandle(tokenizer), modelType: "nemotron_h", defaultMaxTokens: 512,
            stopTokenIDs: stops, promptTokens: prompt, runsTokenConstraints: true, nemotron: true))
        func walk(_ text: String, from start: Int? = nil) -> Int? {
            var state = start ?? constraint.initialState
            for token in tokenizer.encode(text: text, addSpecialTokens: false) {
                guard constraint.allowedTokenIDs(state: state, remainingTokens: 1_000).maskContains(token),
                      let next = constraint.nextState(state: state, tokenID: token) else { return nil }
                state = next
            }
            return state
        }
        let call = "<tool_call>\n<function=computer>\n<parameter=action>\nscroll\n</parameter>\n"
            + "<parameter=scroll_direction>\ndown\n</parameter>\n</function>\n</tool_call>\n"
        let end = try #require(walk(call))
        #expect(constraint.nextState(state: end, tokenID: 11) == -1)
        let opened = try #require(walk("<tool_call>\n<function=computer>\n<parameter=action>\n"))
        #expect(walk("scroll_down\n", from: opened) == nil)
        // Every token a mask admits has a next state in every state these answers pass: over the pieces holding a
        // byte a marker, a frame or a JSON string boundary needs (`<>=/"\\` and controls), or over the whole
        // vocabulary with DARKBLOOM_TEST_NEMOTRON_FULL_SWEEP=1 (minutes).
        let boundaryBytes = Set(Array("<>=/\"\\".utf8) + Array(0..<0x20))
        let ids = ProcessInfo.processInfo.environment["DARKBLOOM_TEST_NEMOTRON_FULL_SWEEP"] == "1"
            ? Array(0..<131_072)
            : (0..<131_072).filter { vocabulary.pieces[$0].contains(where: boundaryBytes.contains) }
        let answers = [call, "Let me look.\n<function=computer>\n<parameter=action>\ntype\n</parameter>\n"
            + "<parameter=text>\nx = 1 <b>\n</parameter>\n</function>\n",
            "<tool_call>\n<function=computer>\n<parameter=action>\nleft_click\n</parameter>\n"
            + "<parameter=coordinate>\n[640, 24]\n</parameter>\n</function>\n</tool_call>\n"]
        for answer in answers {
            var state = constraint.initialState
            for token in tokenizer.encode(text: answer, addSpecialTokens: false) {
                let allowed = constraint.allowedTokenIDs(state: state, remainingTokens: 1_000)
                let disagreeing = ids.first {
                    allowed.maskContains($0) && !stops.contains($0) && constraint.nextState(state: state, tokenID: $0) == nil
                }
                #expect(disagreeing == nil, "state \(state): token \(disagreeing ?? -1)")
                state = try #require(constraint.nextState(state: state, tokenID: token))
            }
        }
    }
}
