import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

/// Nemotron 3.5 Super's `auto` calls under the call grammar, on its owner's
/// route: built from the request plan for text and media alike, read back by
/// Super's own output parser.
enum NemotronSuperToolFixture {
    static let model = NemotronSuperLocalBinding.modelID
    static let stops: Set<Int> = [2, 11]
    static let imEnd = 11
    static let png = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAF0lEQVR4nGP4z8BAEiJN9aiGUQ1DSgMAkPn/Afnh+ngAAAAASUVORK5CYII="

    /// A screenshot turn by default: text and an inline image, the Lightning
    /// suite's tools (none `strict`).
    static func body(image: Bool = true, tools: String? = NemotronToolFixture.tools, extra: String = "") -> Data {
        let content = image
            ? #"[{"type":"text","text":"Scroll down."},{"type":"image_url","image_url":{"url":"\#(png)"}}]"#
            : #""Scroll down.""#
        var body = #"{"model":"\#(model)","messages":[{"role":"user","content":\#(content)}],"max_tokens":512"#
        if let tools { body += #","tools":"# + tools }
        return Data((body + extra + "}").utf8)
    }

    static func plan(_ body: Data) throws -> NemotronSuperRequestPlan {
        try NemotronSuperRequestPlan(body: body, modelID: model)
    }

    static func constraint(_ body: Data, thinking: Bool = true, enabled: Bool = true,
                           runs: Bool = true) throws -> QwenStrictToolConstraint? {
        NemotronSuperToolGrammar.constraint(plan: try plan(body), body: body, tokenizer: NemotronToolFixture.handle,
            promptTokens: NemotronByteTestTokenizer.tokens(NemotronByteTestTokenizer.prompt(thinking: thinking)),
            stopTokenIDs: stops, maxTokens: 512, runsTokenConstraints: runs, enabled: enabled)
    }

    /// The calls Super's own output parser returns for a complete answer.
    static func calls(_ answer: String, _ body: Data) throws -> [ToolCall] {
        var output = try NemotronSuperLocalOutput(plan: try plan(body), streaming: false)
        _ = try output.append(answer)
        return try output.finish().result.calls
    }
}

@Suite("Call grammar: Nemotron 3.5 Super auto calls")
struct NemotronSuperToolGrammarTests {
    private typealias F = NemotronSuperToolFixture
    private typealias L = NemotronToolFixture

    @Test(arguments: [true, false])
    func textAndImageRequestsHoldTheirCallsAndSupersParserReadsThem(image: Bool) throws {
        let body = F.body(image: image)
        #expect(try F.plan(body).hasMedia == image)
        let constraint = try #require(try F.constraint(body))
        #expect(constraint.startsInReasoning)
        let thought = "The page continues below.</think>"
        let call = "<tool_call>\n<function=computer>\n<parameter=action>\nscroll\n</parameter>\n"
            + "<parameter=scroll_direction>\ndown\n</parameter>\n</function>\n</tool_call>\n"
        let end = try #require(L.walk(thought + call, constraint))
        #expect(constraint.nextState(state: end, tokenID: F.imEnd) == -1)
        let calls = try F.calls(thought + call, body)
        #expect(calls.map(\.function.name) == ["computer"])
        #expect(calls.first?.function.arguments["action"] == .string("scroll"))
        #expect(calls.first?.function.arguments["scroll_direction"] == .string("down"))
        // The values the screenshot turns invented, an undeclared parameter, a bound integer's type.
        let open = thought + "<tool_call>\n<function=computer>\n"
        #expect(!L.allows("<parameter=action>\nscroll_down\n", constraint, after: open))
        #expect(!L.allows("<parameter=action>\ndrag_to\n", constraint, after: open))
        #expect(!L.allows("<parameter=to_coordinate>\n", constraint, after: open))
        #expect(!L.allows("<parameter=x>\n0.5", constraint, after: thought + "<tool_call>\n<function=click>\n"))
        #expect(!L.allows("<function=computer>\n<parameter=action>\nscroll_down", constraint, after: thought))
    }

    @Test func theGrammarIsSizedToTheOutputTheBridgeResolves() throws {
        // The body asks 512; the bridge cut it to the window (the engine refuses any other budget).
        let body = F.body()
        let held = try #require(NemotronSuperToolGrammar.constraint(plan: try F.plan(body), body: body,
            tokenizer: L.handle, promptTokens: NemotronByteTestTokenizer.tokens(
                NemotronByteTestTokenizer.prompt(thinking: true)),
            stopTokenIDs: F.stops, maxTokens: 300, runsTokenConstraints: true))
        #expect(held.maxTokens == 300)
    }

    @Test func thinkingOffStartsInTheAnswer() throws {
        let constraint = try #require(try F.constraint(F.body(), thinking: false))
        #expect(!constraint.startsInReasoning)
        #expect(L.walk("<tool_call>\n<function=computer>\n<parameter=action>\nscreenshot\n</parameter>\n"
                       + "</function>\n</tool_call>", constraint) != nil)
    }

    @Test func requestsTheGrammarDoesNotTakeAreServedAsBefore() throws {
        #expect(try F.constraint(F.body(), enabled: false) == nil)
        #expect(try F.constraint(F.body(), runs: false) == nil)
        #expect(try F.constraint(F.body(tools: nil)) == nil)
        #expect(try F.constraint(F.body(extra: #","tool_choice":"none""#)) == nil)
        // A forced choice compiles its own grammar over tools it can hold whole.
        let click = #"[{"type":"function","function":{"name":"click","parameters":{"type":"object","#
            + #""properties":{"x":{"type":"integer"},"y":{"type":"integer"}},"required":["x","y"]}}}]"#
        #expect(try F.constraint(F.body(tools: click, extra: #","tool_choice":"required""#)) == nil)
        #expect(try F.constraint(F.body(tools: click,
            extra: #","tool_choice":{"type":"function","function":{"name":"click"}}"#)) == nil)
        // The bridge holds a reasoning budget or a grammar on a row, not both.
        let budget = F.body(extra: #","reasoning":{"max_tokens":64}"#)
        #expect(try F.plan(budget).nativeReasoningBudget != nil)
        #expect(try F.constraint(budget) == nil)
        // With `force_nonempty_content` an unterminated thought becomes the answer and its calls are parsed: the
        // grammar, which leaves reasoning free, does not take such a request unless thinking is off.
        let forced = #","chat_template_kwargs":{"force_nonempty_content":true}"#
        #expect(try F.plan(F.body(extra: forced)).controls.forceNonemptyContent)
        #expect(try F.constraint(F.body(extra: forced)) == nil)
        #expect(try F.constraint(F.body(extra: forced + #","enable_thinking":false"#), thinking: false) != nil)
        // `parallel_tool_calls: false` holds one call.
        let single = try #require(try F.constraint(F.body(extra: #","parallel_tool_calls":false"#), thinking: false))
        let one = "<tool_call>\n<function=computer>\n<parameter=action>\nscreenshot\n</parameter>\n</function>\n</tool_call>\n"
        #expect(!L.allows("<tool_call>", single, after: one))
    }

    @Test func theSwitchReadsOffWordsAndReachesTheProviderJob() {
        typealias G = NemotronSuperToolGrammar
        for word in ["off", "0", "false", "no", "none", "disabled", " OFF "] {
            #expect(!G.enabled(environment: [G.environmentKey: word]), "\(word)")
        }
        for word in ["", "on", "1", "true", "yes"] {
            #expect(G.enabled(environment: [G.environmentKey: word]), "\(word)")
        }
        #expect(G.enabled(environment: [:]))
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(G.environmentKey))
        // Lightning's switch does not reach Super, nor Super's Lightning.
        #expect(G.environmentKey != QwenStrictToolGrammar.nemotronEnvironmentKey)
    }

    @Test func aConstrainedRowKeepsItsLoopGuardButNotTheExit() throws {
        let plan = try F.plan(F.body(image: false))
        let exit = GenerationLoopExitThinking(openMarker: "<think>", closeMarker: "</think>", exitTokens: [13],
            exitText: "</think>", startsInside: true, record: GenerationLoopExitRecord())
        let constraint = try #require(try F.constraint(F.body(image: false)))
        let free = try #require(plan.loopGuard(setting: .modelTypes(["nemotron_h_omni"]), exitThinking: exit))
        #expect(free.exitThinking != nil)
        let held = try #require(plan.loopGuard(setting: .modelTypes(["nemotron_h_omni"]), exitThinking: exit,
                                               tokenConstraint: constraint))
        #expect(held.exitThinking == nil)
    }

    @Test func aTypelessParameterIsStillHeldByName() throws {
        // Ingress normalization types the rendered property; the declaration as sent has none.
        let tools = #"[{"type":"function","function":{"name":"note","parameters":{"type":"object","#
            + #""properties":{"body":{"description":"anything"},"pin":{"type":"boolean"}},"required":["body"],"#
            + #""additionalProperties":false}}}]"#
        let body = F.body(image: false, tools: tools)
        let constraint = try #require(try F.constraint(body, thinking: false))
        let open = "<tool_call>\n<function=note>\n"
        #expect(L.allows("<parameter=body>\nfree text\n</parameter>\n</function>\n</tool_call>", constraint, after: open))
        #expect(!L.allows("<parameter=title>\n", constraint, after: open))
        #expect(!L.allows("<parameter=pin>\nmaybe", constraint, after: open))
    }
}

/// `DARKBLOOM_TEST_NEMOTRON_SUPER_TOKENIZER_DIR=<Super snapshot>` (its
/// tokenizer, configs and `chat_template.jinja`): the shipped tokenizer holds
/// the call markers at the pinned ids, and prompts rendered from the pinned
/// template, text and image, start the grammar where the model writes.
@Suite("Call grammar: Nemotron 3.5 Super real tokenizer",
       .enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_TEST_NEMOTRON_SUPER_TOKENIZER_DIR"] != nil))
struct NemotronSuperToolGrammarRealTokenizerTests {
    private typealias F = NemotronSuperToolFixture

    @Test func theShippedTokenizerAndTemplateStartTheGrammarWhereTheModelWrites() async throws {
        let key = "DARKBLOOM_TEST_NEMOTRON_SUPER_TOKENIZER_DIR"
        let (tokenizer, stops) = try await JSONAnswerRealTokenizerCheck.load(key)
        #expect(stops == F.stops)
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment[key]))
        let template = try Data(contentsOf: directory.appendingPathComponent("chat_template.jinja"))
        let vocabulary = try JSONAnswerVocabulary(tokenizer: tokenizer, profile: QwenStrictToolGrammar.nemotronProfile,
                                                  stopTokenIDs: stops)
        #expect(vocabulary.pieceTokenIDs.count == 131_072 - 1_000 + 4)
        let handle = TokenizerHandle(tokenizer)
        func constraint(_ body: Data, prompt: [Int]) throws -> QwenStrictToolConstraint {
            try #require(NemotronSuperToolGrammar.constraint(plan: try F.plan(body), body: body, tokenizer: handle,
                promptTokens: prompt, stopTokenIDs: stops, maxTokens: 512, runsTokenConstraints: true))
        }
        func walk(_ text: String, _ constraint: QwenStrictToolConstraint) -> Int? {
            var state = constraint.initialState
            for token in tokenizer.encode(text: text, addSpecialTokens: false) {
                guard constraint.allowedTokenIDs(state: state, remainingTokens: 1_000).maskContains(token),
                      let next = constraint.nextState(state: state, tokenID: token) else { return nil }
                state = next
            }
            return state
        }
        let call = "<tool_call>\n<function=computer>\n<parameter=action>\nscroll\n</parameter>\n"
            + "<parameter=scroll_direction>\ndown\n</parameter>\n</function>\n</tool_call>\n"
        for thinking in [true, false] {
            let flag = #","enable_thinking":\#(thinking)"#
            let text = F.body(image: false, extra: flag), image = F.body(extra: flag)
            let textPrompt = try F.plan(text).textPromptTokens(body: text, templateBytes: template,
                                                               tokenizer: tokenizer)
            let imagePrompt = try F.plan(image).imagePromptTokens(body: image, templateBytes: template,
                tokenizer: tokenizer, featureCounts: [4], contextLength: 65_536)
            #expect(imagePrompt.filter { $0 == 18 }.count == 4)
            for (body, prompt) in [(text, textPrompt), (image, imagePrompt)] {
                let held = try constraint(body, prompt: prompt)
                #expect(held.startsInReasoning == thinking)
                let answer = (thinking ? "Scrolling.</think>" : "") + call
                let end = try #require(walk(answer, held))
                #expect(held.nextState(state: end, tokenID: F.imEnd) == -1)
                #expect(walk((thinking ? "x</think>" : "") + "<tool_call>\n<function=computer>\n"
                             + "<parameter=action>\nscroll_down\n", held) == nil)
            }
        }
    }
}
