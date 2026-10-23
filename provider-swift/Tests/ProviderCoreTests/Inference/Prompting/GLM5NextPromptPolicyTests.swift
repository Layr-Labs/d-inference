import CryptoKit
import Foundation
import Jinja
import MLXLMCommon
import MLXLMServer
import ProviderCoreFoundation
import Testing

@testable import ProviderCore

@Suite("Pinned GLM5 native prompt policy")
struct GLM5NextPromptPolicyTests {
    private var fixtures: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("fixtures/prompt-contract/glm53-flash")
    }

    private struct Corpus: Decodable {
        struct Case: Decodable {
            let id: String
            let request: MLXLMCommon.JSONValue
            let expectedContext: MLXLMCommon.JSONValue
            let rendered: String
            let renderedSHA256: String
            enum CodingKeys: String, CodingKey {
                case id, request, rendered
                case expectedContext = "expected_context"
                case renderedSHA256 = "rendered_sha256"
            }
        }
        let templateSHA256: String
        let cases: [Case]
        enum CodingKeys: String, CodingKey {
            case cases
            case templateSHA256 = "template_sha256"
        }
    }

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func requestAndControls(_ body: Data) throws -> (OpenAIChatCompletionRequest, ChatTemplateControls) {
        let request = try ProviderLoop.decodeOpenAIRequest(body, modelType: "glm5_next")
        let controls = ProviderLoop.extractChatTemplateControls(from: body)
        return (request, controls)
    }

    private func normalized(_ body: Data) throws -> ProviderPromptContractPipeline.NormalizedInput {
        let (request, controls) = try requestAndControls(body)
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "glm5_next")
        return try ProviderPromptContractPipeline.normalizedInput(
            prepared: prepared, request: request, modelType: "glm5_next", templateControls: controls)
    }

    /// Official upstream template: the golden rendering authority, never a
    /// loadable identity under the pinned Swift-Jinja.
    private static let officialTemplateSHA256 = "0c4099f3382d6c92700dfb99725025360966fd73032f0ecf32377c0d9e6309c5"

    /// The shipped template exactly as the serving tokenizer compiles it.
    private func shippedTemplate() throws -> Template {
        let source = try Data(contentsOf: fixtures.appendingPathComponent("eigenlabs-chat_template.jinja"))
        #expect(source.count == 10_954)
        #expect(sha(source) == GLM5NextPromptPolicy.templateSHA256)
        let text = String(decoding: source, as: UTF8.self)
        let served = NemotronTemplateFilters.bindingFilters(
            in: normalizeSwiftJinjaTemplate(text), modelType: "glm5_next")
        #expect(served == text)
        return try Template(served, with: .init(lstripBlocks: true, trimBlocks: true))
    }

    @Test func shippedTemplateIsTheOfficialSourceWithSubscriptAccessOnly() throws {
        let official = try String(
            contentsOf: fixtures.appendingPathComponent("chat_template.jinja"), encoding: .utf8)
        let shipped = try String(
            contentsOf: fixtures.appendingPathComponent("eigenlabs-chat_template.jinja"), encoding: .utf8)
        #expect(official.utf8.count == 10_950)
        #expect(sha(Data(official.utf8)) == Self.officialTemplateSHA256)
        #expect(official.components(separatedBy: ".0.").count == 5)
        #expect(official.replacingOccurrences(of: ".0.", with: "[0].") == shipped)
        // Why the official identity is not accepted: the pinned renderer
        // rejects numeric attribute access at parse time.
        #expect(throws: (any Error).self) {
            try Template(official, with: .init(lstripBlocks: true, trimBlocks: true))
        }
    }

    private func goldens() throws -> Corpus {
        try JSONDecoder().decode(Corpus.self,
            from: Data(contentsOf: fixtures.appendingPathComponent("goldens.json")))
    }

    /// The coordinator-path and local-HTTP normalizations of one request body.
    private func remoteAndLocalInputs(_ body: Data) throws -> [ProviderPromptContractPipeline.NormalizedInput] {
        let local = try JSONDecoder().decode(LocalChatRequest.self, from: body)
        let localInput = try ProviderPromptContractPipeline.normalizedInput(
            prepared: ToolChoicePromptPolicy.prepare(local.request, modelType: "glm5_next"),
            request: local.request, modelType: "glm5_next", templateControls: local.templateControls)
        return [try normalized(body), localInput]
    }

    private func render(_ input: ProviderPromptContractPipeline.NormalizedInput, with template: Template) throws -> String {
        var values: [String: Jinja.Value] = [
            "messages": try .init(any: input.messages),
            "add_generation_prompt": .boolean(true),
        ]
        if let tools = input.tools { values["tools"] = try .init(any: tools) }
        for (key, value) in input.additionalContext ?? [:] {
            values[key] = try .init(any: value)
        }
        return try template.render(values)
    }

    @Test func shippedTemplateAndFullPolicyRendersMatchOfficialGoldens() throws {
        let corpus = try goldens()
        #expect(corpus.templateSHA256 == Self.officialTemplateSHA256)
        #expect(corpus.cases.count == 7)
        let template = try shippedTemplate()
        for fixture in corpus.cases {
            for input in try remoteAndLocalInputs(JSONEncoder().encode(fixture.request)) {
                let context = MLXLMCommon.JSONValue.object(
                    (input.additionalContext ?? [:]).mapValues { .from($0) })
                #expect(context == fixture.expectedContext)
                let rendered = try render(input, with: template)
                #expect(Data(rendered.utf8) == Data(fixture.rendered.utf8), "\(fixture.id)")
                #expect(sha(Data(rendered.utf8)) == fixture.renderedSHA256, "\(fixture.id)")
                #expect(ReasoningPromptProbe.streamingPrefix(forPromptTail: rendered) == "<think>")
            }
        }
    }

    /// OpenRouter's unified reasoning object and the template-kwargs switches,
    /// in the values that keep reasoning on and visible. The template always
    /// reasons, so each must leave every golden render byte-identical.
    private static var noOpReasoningControls: [[String: Any]] { [
        ["reasoning": ["enabled": true]],
        ["reasoning": ["exclude": false]],
        ["include_reasoning": true],
        ["enable_thinking": true],
        ["chat_template_kwargs": ["enable_thinking": true]],
        ["chat_template_kwargs": ["thinking": true]],
        ["thinking": ["type": "enabled"]],
        ["thinking": true],
        ["include_reasoning": NSNull(), "thinking": NSNull()],
        ["reasoning": ["enabled": true, "max_tokens": NSNull(), "exclude": NSNull(), "summary": "auto"]],
        ["reasoning": ["enabled": true, "exclude": false], "include_reasoning": true,
         "enable_thinking": true, "chat_template_kwargs": ["thinking": true, "enable_thinking": true]],
    ] }

    /// Merge controls into a request, extending rather than replacing an
    /// existing `reasoning` or `chat_template_kwargs` object.
    private func adding(_ controls: [String: Any], to request: MLXLMCommon.JSONValue) throws -> Data {
        var body = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        for (key, value) in controls {
            if let nested = value as? [String: Any], let existing = body[key] as? [String: Any] {
                body[key] = existing.merging(nested) { _, added in added }
            } else {
                body[key] = value
            }
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    @Test func openRouterReasoningSwitchesAreNoOpsThatLeaveEveryGoldenRenderUnchanged() throws {
        let template = try shippedTemplate()
        for fixture in try goldens().cases {
            for controls in Self.noOpReasoningControls {
                let body = try adding(controls, to: fixture.request)
                let evidence = try JSONDecoder().decode(GLM5NextPromptPolicy.RawControls.self, from: body)
                #expect(
                    !evidence.invalid && !evidence.disablesThinking && !evidence.excludesReasoning,
                    "\(fixture.id) \(controls)")
                for input in try remoteAndLocalInputs(body) {
                    let context = MLXLMCommon.JSONValue.object(
                        (input.additionalContext ?? [:]).mapValues { .from($0) })
                    #expect(context == fixture.expectedContext, "\(fixture.id) \(controls)")
                    #expect(try render(input, with: template) == fixture.rendered, "\(fixture.id) \(controls)")
                }
            }
        }
    }

    @Test func reasoningBudgetSelectsTheNearestEffortAndAnyExplicitEffortWins() throws {
        func effort(_ controls: [String: Any]) throws -> String? {
            var body: [String: Any] = ["model": "m", "messages": [["role": "user", "content": "Hi"]]]
            body.merge(controls) { _, added in added }
            let inputs = try remoteAndLocalInputs(JSONSerialization.data(withJSONObject: body))
            let efforts = inputs.map { $0.additionalContext?["reasoning_effort"] as? String }
            #expect(Set(efforts).count == 1, "\(controls)")
            return efforts[0]
        }
        for (budget, expected) in [(1, "low"), (1024, "low"), (1025, "high"), (8192, "high"),
            (8193, "max"), (Int.max, "max")] {
            #expect(try effort(["reasoning": ["max_tokens": budget]]) == expected, "\(budget)")
        }
        #expect(try effort(["reasoning": ["max_tokens": 100, "effort": "max"]]) == "max")
        #expect(try effort(["reasoning": ["max_tokens": 100_000], "reasoning_effort": "minimal"]) == "low")
        #expect(try effort(["reasoning": ["max_tokens": 100_000],
            "chat_template_kwargs": ["reasoning_effort": "medium"]]) == "high")
        #expect(try effort(["reasoning": ["max_tokens": 2048, "enabled": true, "exclude": false]]) == "high")
    }

    /// Every thinking-off spelling. Each adds `enable_thinking: false`, which
    /// `GLM5NextThinkingTokenizer` turns into a closed `<think></think>`.
    private static var thinkingOffControls: [[String: Any]] { [
        ["reasoning": ["enabled": false]],
        ["reasoning": ["effort": "none"]],
        ["reasoning_effort": "none"],
        ["reasoning_effort": "off"],
        ["enable_thinking": false],
        ["chat_template_kwargs": ["enable_thinking": false]],
        ["chat_template_kwargs": ["thinking": false]],
        ["chat_template_kwargs": ["reasoning_effort": "none"]],
        ["thinking": ["type": "disabled"]],
        ["thinking": false],
        ["reasoning": ["enabled": false, "exclude": false], "enable_thinking": false,
         "include_reasoning": true, "chat_template_kwargs": ["thinking": false]],
    ] }

    /// Hidden reasoning: the provider cannot withhold reasoning it generates.
    private static var reasoningExclusionControls: [[String: Any]] { [
        ["reasoning": ["exclude": true]],
        ["include_reasoning": false],
        ["reasoning": ["enabled": false, "exclude": true]],
    ] }

    /// Thinking-off beside a thinking-on switch, effort level or budget.
    private static var contradictoryThinkingControls: [[String: Any]] { [
        ["reasoning": ["effort": "off", "max_tokens": 1024]],
        ["reasoning": ["effort": "high"], "enable_thinking": false],
        ["reasoning": ["effort": "none"], "reasoning_effort": "high"],
        ["reasoning": ["enabled": true], "chat_template_kwargs": ["thinking": false]],
        ["enable_thinking": true, "chat_template_kwargs": ["enable_thinking": false]],
        ["thinking": ["type": "disabled"], "reasoning": ["effort": "high"]],
        ["thinking": ["type": "enabled"], "reasoning_effort": "none"],
    ] }

    private func body(_ controls: [String: Any]) throws -> Data {
        var object: [String: Any] = ["model": "m", "messages": [["role": "user", "content": "Hi"]]]
        object.merge(controls) { _, added in added }
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func everyThinkingOffSpellingClosesThinkingOnBothPaths() throws {
        for controls in Self.thinkingOffControls {
            let body = try body(controls)
            let evidence = try JSONDecoder().decode(GLM5NextPromptPolicy.RawControls.self, from: body)
            #expect(!evidence.invalid && evidence.disablesThinking && !evidence.requestsThinking, "\(controls)")
            _ = try ProviderLoop.decodeOpenAIRequest(body, modelType: "glm5_next")
            for input in try remoteAndLocalInputs(body) {
                #expect(input.additionalContext?["enable_thinking"] as? Bool == false, "\(controls)")
                #expect(input.additionalContext?["reasoning_effort"] as? String == "max", "\(controls)")
                #expect(input.additionalContext?["clear_thinking"] as? Bool == false, "\(controls)")
            }
        }
        // Typed controls without raw evidence (the Responses translation and
        // direct callers) reach the same context.
        let request = OpenAIChatCompletionRequest(model: "m", messages: [])
        let typed: [(OpenAIChatCompletionRequest, ChatTemplateControls)] = [
            (request, .init(enableThinking: false)), (request, .init(reasoningEffort: "none")),
            (request, .init(reasoningEffort: "off")),
            (.init(model: "m", messages: [], reasoning: .init(enabled: false)), .init()),
            (.init(model: "m", messages: [], reasoning: .init(effort: "none")), .init()),
        ]
        for (request, controls) in typed {
            let context = try GLM5NextPromptPolicy.additionalContext(request: request, controls: controls)
            #expect(context["enable_thinking"] as? Bool == false)
        }
        // Thinking on, the default, renders exactly as before.
        let context = try GLM5NextPromptPolicy.additionalContext(request: request, controls: .init())
        #expect(context["enable_thinking"] == nil)
    }

    @Test func reasoningExclusionAndContradictionsAreRefusedOnBothPaths() throws {
        for controls in Self.reasoningExclusionControls {
            let body = try body(controls)
            let evidence = try JSONDecoder().decode(GLM5NextPromptPolicy.RawControls.self, from: body)
            #expect(!evidence.invalid && evidence.excludesReasoning, "\(controls)")
            #expect(throws: MultiModelBatchSchedulerEngineError.reasoningExclusionUnsupported) {
                try ProviderLoop.decodeOpenAIRequest(body, modelType: "glm5_next")
            }
            let local = try JSONDecoder().decode(LocalChatRequest.self, from: body)
            #expect(throws: MultiModelBatchSchedulerEngineError.reasoningExclusionUnsupported) {
                try ProviderPromptContractPipeline.normalizedInput(
                    prepared: ToolChoicePromptPolicy.prepare(local.request, modelType: "glm5_next"),
                    request: local.request, modelType: "glm5_next", templateControls: local.templateControls)
            }
            // Other families keep their own handling of the same bodies.
            try ProviderPromptContractPipeline.validateNativeControls(local.templateControls, modelType: "llama")
        }
        for controls in Self.contradictoryThinkingControls {
            let body = try body(controls)
            let evidence = try JSONDecoder().decode(GLM5NextPromptPolicy.RawControls.self, from: body)
            #expect(evidence.disablesThinking && evidence.requestsThinking, "\(controls)")
            #expect(throws: (any Error).self) { try evidence.validate() }
            let local = try JSONDecoder().decode(LocalChatRequest.self, from: body)
            #expect(throws: (any Error).self) {
                try ProviderPromptContractPipeline.normalizedInput(
                    prepared: ToolChoicePromptPolicy.prepare(local.request, modelType: "glm5_next"),
                    request: local.request, modelType: "glm5_next", templateControls: local.templateControls)
            }
        }
        let request = OpenAIChatCompletionRequest(model: "m", messages: [], reasoning: .init(effort: "high"))
        #expect(throws: (any Error).self) {
            try GLM5NextPromptPolicy.additionalContext(request: request, controls: .init(enableThinking: false))
        }
        // A malformed sibling remains the generic refusal.
        let malformed = Data(#"{"model":"m","messages":[],"reasoning":{"enabled":false,"mode":"pro"}}"#.utf8)
        #expect(try JSONDecoder().decode(GLM5NextPromptPolicy.RawControls.self, from: malformed).invalid)
    }

    @Test func thinkingTokenizerClosesOnlyAnOpenGenerationPromptWhenThinkingIsOff() throws {
        let tokenizer = try GLM5NextThinkingTokenizer(base: ThinkFixtureTokenizer())
        let messages: [[String: any Sendable]] = [["role": "user", "content": "Hi"]]
        let open = ThinkFixtureTokenizer.prompt
        #expect(try tokenizer.applyChatTemplate(messages: messages, tools: nil, additionalContext: nil) == open)
        #expect(try tokenizer.applyChatTemplate(
            messages: messages, tools: nil, additionalContext: ["reasoning_effort": "max"]) == open)
        #expect(try tokenizer.applyChatTemplate(
            messages: messages, tools: nil, additionalContext: ["enable_thinking": false])
            == open + [ThinkFixtureTokenizer.close])
        #expect(try tokenizer.applyChatTemplate(
            messages: messages, chatTemplate: "t", tools: nil, additionalContext: ["enable_thinking": false])
            == open + [ThinkFixtureTokenizer.close])
        var unopened = ThinkFixtureTokenizer()
        unopened.rendered = [1, 2]
        #expect(throws: GLM5NextThinkingTokenizer.Failure.generationPromptNotOpen) {
            try GLM5NextThinkingTokenizer(base: unopened).applyChatTemplate(
                messages: messages, tools: nil, additionalContext: ["enable_thinking": false])
        }
        var missing = ThinkFixtureTokenizer()
        missing.hasThinkTokens = false
        #expect(throws: GLM5NextThinkingTokenizer.Failure.missingThinkTokens) {
            try GLM5NextThinkingTokenizer(base: missing)
        }
        #expect(tokenizer.decode(tokenIds: [ThinkFixtureTokenizer.open, ThinkFixtureTokenizer.close],
            skipSpecialTokens: false) == "<think></think>")
    }

    /// The shipped template's generation prompt ends with the open block that
    /// thinking-off closes.
    @Test func shippedTemplateGenerationPromptEndsWithAnOpenThinkBlock() throws {
        let template = try shippedTemplate()
        let input = try remoteAndLocalInputs(try body(["enable_thinking": false]))[0]
        let rendered = try render(input, with: template)
        #expect(rendered.hasSuffix("<|assistant|><think>"))
        #expect(ReasoningPromptProbe.streamingPrefix(forPromptTail: rendered + "</think>") == "<think></think>")
    }

    @Test func reasoningRefusalIsAClient400WithAFixedMessageThatNeverCrossesToTheCoordinator() throws {
        let error = MultiModelBatchSchedulerEngineError.reasoningExclusionUnsupported
        #expect(error.errorDescription == GLM5NextPromptPolicy.reasoningExclusionUnsupportedMessage)
        #expect(ProviderLoop.mapInferenceErrorToStatus(error) == 400)
        let failure = ProviderLoop.sanitizedInferenceFailure(from: error, phase: .request)
        #expect(failure.statusCode == 400)
        #expect(failure.code == .invalidRequest)
        #expect(failure.errorReason == .clientError)
        #expect(classifyInferenceErrorReason(error) == nil)
        let wire = try ProviderProtocolCodec.encodeProviderMessage(
            .inferenceError(.init(requestId: "glm-reasoning-fixture", failure: failure)))
        let json = try #require(JSONSerialization.jsonObject(with: wire) as? [String: Any])
        #expect(json["status_code"] as? Int == 400)
        #expect(json["error_reason"] as? String == "client_error")
        #expect(json["error"] as? String == InferenceFailureCode.invalidRequest.message)
    }

    @Test func additionalEffortAndImageMarkerGoldensMatchOfficial() throws {
        let corpus = try JSONDecoder().decode(Corpus.self,
            from: Data(contentsOf: fixtures.appendingPathComponent("additional-goldens.json")))
        #expect(corpus.templateSHA256 == Self.officialTemplateSHA256)
        #expect(Set(corpus.cases.map(\.id)) == ["minimal", "medium", "xhigh", "image"])
        let template = try shippedTemplate()
        for fixture in corpus.cases {
            let body = try JSONEncoder().encode(fixture.request)
            var values: [String: Jinja.Value] = ["add_generation_prompt": .boolean(true)]
            if fixture.id == "image" {
                // Renderer-only marker evidence: no image fetch or native owner.
                // The text-only ingress must continue refusing this request.
                #expect(throws: (any Error).self) { try normalized(body) }
                let request = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                values["messages"] = try .init(any: try #require(request["messages"]))
                values["reasoning_effort"] = .string("max")
                values["clear_thinking"] = .boolean(false)
            } else {
                let input = try normalized(body)
                #expect(MLXLMCommon.JSONValue.object((input.additionalContext ?? [:]).mapValues { .from($0) })
                    == fixture.expectedContext)
                values["messages"] = try .init(any: input.messages)
                for (key, value) in input.additionalContext ?? [:] { values[key] = try .init(any: value) }
            }
            let rendered = try template.render(values)
            #expect(Data(rendered.utf8) == Data(fixture.rendered.utf8), "\(fixture.id)")
            #expect(sha(Data(rendered.utf8)) == fixture.renderedSHA256, "\(fixture.id)")
        }
    }

    /// The goldens hold only string tool results. These list-shaped results
    /// reach all four rewritten `[0]` accesses; the expected bytes are the
    /// official template's Jinja2 3.1.6 render of each shape.
    @Test func shippedTemplateRendersRewrittenToolResultBranchesLikeOfficial() throws {
        let template = try shippedTemplate()
        let call: [String: any Sendable] = [
            "role": "assistant", "content": "",
            "tool_calls": [[
                "id": "c1", "type": "function",
                "function": ["name": "lookup", "arguments": ["q": "x"] as [String: any Sendable]]
                    as [String: any Sendable],
            ] as [String: any Sendable]],
        ]
        let parts: [[String: any Sendable]] = [["type": "text", "text": "R"]]
        let results: [String: [String: any Sendable]] = [
            "text parts": ["role": "tool", "tool_call_id": "c1", "content": parts],
            "ordered outputs": [
                "role": "tool", "content": [["tool_call_id": "c1", "output": parts] as [String: any Sendable]],
            ],
            "unordered outputs": ["role": "tool", "content": [["output": parts] as [String: any Sendable]]],
        ]
        for (name, result) in results {
            let messages: [[String: any Sendable]] = [["role": "user", "content": "go"], call, result]
            let rendered = try template.render([
                "messages": try .init(any: messages), "add_generation_prompt": .boolean(true),
            ])
            #expect(rendered == "[gMASK]<sop><|system|>Reasoning Effort: Max<|user|>go<|assistant|><think></think><tool_call>lookup<arg_key>q</arg_key><arg_value>x</arg_value></tool_call><|observation|><tool_response>R</tool_response><|assistant|><think>", "\(name)")
        }
    }

    @Test func exactFamilySelectionDoesNotFollowUserModelNames() {
        for type in ["glm5_next", "glm5_next_text", "glm5_next_mtp"] {
            #expect(GLM5NextPromptPolicy.applies(modelType: type))
        }
        for type: String? in [nil, "glm5", "glm4", "glm5_next_vision", "GLM5_NEXT", " glm5_next"] {
            #expect(!GLM5NextPromptPolicy.applies(modelType: type))
        }
    }

    @Test func effortAndClearThinkingHaveDistinctSemantics() throws {
        let request = OpenAIChatCompletionRequest(model: "not-registered", messages: [])
        for effort in ["low", "high", "max"] {
            for clear in [false, true] {
                let context = try GLM5NextPromptPolicy.additionalContext(request: request,
                    controls: .init(reasoningEffort: effort, clearThinking: clear))
                #expect(context["reasoning_effort"] as? String == effort)
                #expect(context["clear_thinking"] as? Bool == clear)
                #expect(context["enable_thinking"] == nil)
                #expect(context["preserve_thinking"] == nil)
            }
        }
        // OpenAI effort names map to the nearest level the template renders.
        for (requested, rendered) in [("minimal", "low"), ("medium", "high"), ("xhigh", "max")] {
            let context = try GLM5NextPromptPolicy.additionalContext(request: request,
                controls: .init(reasoningEffort: requested))
            #expect(context["reasoning_effort"] as? String == rendered)
        }
        let nested = OpenAIChatCompletionRequest(model: "not-registered", messages: [],
            reasoning: .init(effort: "medium"))
        #expect(try GLM5NextPromptPolicy.additionalContext(request: nested, controls: .init())[
            "reasoning_effort"] as? String == "high")
        // `none`/`off` turn thinking off (`everyThinkingOffSpellingClosesThinkingOnBothPaths`).
        for effort in ["0", "MEDIUM", "LOW", " low", ""] {
            #expect(throws: (any Error).self) {
                try GLM5NextPromptPolicy.additionalContext(request: request,
                    controls: .init(reasoningEffort: effort))
            }
        }
        // Enabling thinking is the template's only mode, so it is a no-op.
        let enabled = try GLM5NextPromptPolicy.additionalContext(request: request,
            controls: .init(enableThinking: true))
        #expect(enabled["reasoning_effort"] as? String == "max")
        #expect(enabled["enable_thinking"] == nil)
        let nestedEnabled = OpenAIChatCompletionRequest(model: "not-registered", messages: [],
            reasoning: .init(enabled: true, effort: "low"))
        #expect(try GLM5NextPromptPolicy.additionalContext(request: nestedEnabled, controls: .init())[
            "reasoning_effort"] as? String == "low")
        #expect(throws: (any Error).self) {
            try GLM5NextPromptPolicy.additionalContext(request: request,
                controls: .init(preserveThinking: false))
        }
    }

    @Test func malformedAndShadowedRawControlsFailClosed() throws {
        let controls: [[String: Any]] = [
            ["reasoning_effort": NSNull()], ["reasoning_effort": false], ["reasoning_effort": "None"],
            ["reasoning_effort": " none"], ["reasoning_effort": "0"],
            ["clear_thinking": NSNull()], ["clear_thinking": 0], ["clear_thinking": "false"],
            ["enable_thinking": NSNull()], ["enable_thinking": 1], ["enable_thinking": "true"],
            ["include_reasoning": "true"], ["include_reasoning": 0],
            ["preserve_thinking": true], ["preserve_thinking": NSNull()],
            ["thinking": "enabled"], ["thinking": 1], ["thinking": ["type": "adaptive"]],
            ["thinking": ["type": "enabled", "budget_tokens": 1024]], ["thinking": ["type": NSNull()]],
            ["thinking": ["type": "enabled", "clear_thinking": "false"]],
            ["reasoning": true], ["reasoning": ["enabled": 1]], ["reasoning": ["exclude": "false"]],
            ["reasoning": ["max_tokens": 0]], ["reasoning": ["max_tokens": -1]],
            ["reasoning": ["max_tokens": 1.5]], ["reasoning": ["max_tokens": "1024"]],
            ["reasoning": ["summary": "verbose"]], ["reasoning": ["summary": true]],
            ["reasoning": ["generate_summary": "Auto"]], ["reasoning": ["context": "all_turns"]],
            ["reasoning": ["effort": "high"], "reasoning_effort": "low "],
            ["reasoning": ["enabled": false, "unrecognized": true]],
            ["clear_thinking": false, "chat_template_kwargs": ["clear_thinking": "true"]],
            ["chat_template_kwargs": ["thinking": "true"]],
            ["chat_template_kwargs": ["unrecognized": true]],
        ]
        for var body in controls {
            body["model"] = "fixture-glm5-not-registered"
            body["messages"] = [["role": "user", "content": "Hello."]]
            let evidence = try JSONDecoder().decode(GLM5NextPromptPolicy.RawControls.self,
                from: JSONSerialization.data(withJSONObject: body))
            #expect(evidence.invalid)
            #expect(throws: (any Error).self) { try evidence.validate() }
        }
    }

    @Test func precedenceValidatesEveryAliasAndDateCaptureRetainsEvidence() throws {
        let body = Data(#"{"model":"m","messages":[],"reasoning":{"effort":"high"},"reasoning_effort":"low","clear_thinking":false,"chat_template_kwargs":{"reasoning_effort":"max","clear_thinking":true}}"#.utf8)
        let (request, controls) = try requestAndControls(body)
        let captured = controls.resolvingPromptDate(at: Date(timeIntervalSince1970: 0))
        #expect(captured.rawGLM5Controls == controls.rawGLM5Controls)
        let context = try GLM5NextPromptPolicy.additionalContext(request: request, controls: captured)
        #expect(context["reasoning_effort"] as? String == "high")
        #expect(context["clear_thinking"] as? Bool == false)
    }

    @Test func decodedControlsCarryClearThinkingWithTopLevelPrecedence() throws {
        for (json, expected) in [
            (#"{"clear_thinking":true}"#, true),
            (#"{"chat_template_kwargs":{"clear_thinking":true}}"#, true),
            (#"{"clear_thinking":false,"chat_template_kwargs":{"clear_thinking":true}}"#, false),
            (#"{}"#, nil),
        ] as [(String, Bool?)] {
            let controls = ProviderLoop.extractChatTemplateControls(from: Data(json.utf8))
            #expect(controls.clearThinking == expected, "\(json)")
            #expect(controls.clearThinking == controls.rawGLM5Controls.clearThinking)
        }
    }

    @Test func modesDoNotAdvertiseConstrainedDecodingFromInstructions() throws {
        let tool = OpenAITool(function: .init(name: "ping", parameters: .object([
            "type": .string("object"), "properties": .object([:]),
        ])))
        for choice: OpenAIToolChoice in [.mode(.required), .function(name: "ping")] {
            let request = OpenAIChatCompletionRequest(model: "m", messages: [], tools: [tool], toolChoice: choice)
            #expect(throws: (any Error).self) {
                try GLM5NextPromptPolicy.normalizedTextInput(request: request,
                    prepared: ToolChoicePromptPolicy.prepare(request, modelType: "glm5_next"), controls: .init())
            }
        }
        let json = OpenAIChatCompletionRequest(model: "m", messages: [], responseFormat: .jsonObject())
        #expect(throws: (any Error).self) {
            try GLM5NextPromptPolicy.normalizedTextInput(request: json,
                prepared: ToolChoicePromptPolicy.prepare(json, modelType: "glm5_next"), controls: .init())
        }
        let none = OpenAIChatCompletionRequest(model: "m", messages: [], tools: [tool], toolChoice: .mode(.none), parallelToolCalls: false)
        let prepared = try ToolChoicePromptPolicy.prepare(none, modelType: "glm5_next")
        #expect(!prepared.allowsParallelCalls)
        #expect(try GLM5NextPromptPolicy.normalizedTextInput(request: none, prepared: prepared, controls: .init()).tools == nil)
    }

    @Test func toolHistoryCorrelationIsExactAndArgumentsMustBeObjects() throws {
        func request(id: String, resultID: String, arguments: String = "{}") -> OpenAIChatCompletionRequest {
            .init(model: "m", messages: [
                .init(role: .assistant, content: .null,
                    toolCalls: [.init(id: id, function: .init(name: "f", arguments: arguments))]),
                .init(role: .tool, content: .text("result"), toolCallID: resultID),
            ])
        }
        for candidate in [request(id: "é", resultID: "e\u{301}"), request(id: "a", resultID: "b"),
            request(id: "a", resultID: "a", arguments: "[null]"), request(id: "a", resultID: "a", arguments: "{bad}"),
            request(id: "a", resultID: "a", arguments: "{\"n\":18446744073709551615}"),
            request(id: "a", resultID: "a", arguments: "{\"n\":1,\"n\":2}")] {
            #expect(throws: (any Error).self) {
                try GLM5NextPromptPolicy.normalizedTextInput(request: candidate,
                    prepared: ToolChoicePromptPolicy.prepare(candidate, modelType: "glm5_next"), controls: .init())
            }
        }
    }

    @Test func actualModelIdentityRestoresRawSchemasWithoutChangingOtherFamilies() throws {
        let body = Data(#"{"model":"arbitrary","model_type":"glm5_next","messages":[{"role":"user","content":"Hi"}],"tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object","properties":{"allow":true,"flag":{"type":["boolean","null"]},"count":{"type":["integer","null"]},"text":{"type":["string","null"]}}}}}]}"#.utf8)
        // Keep fixture syntax failures separate from normalization failures.
        _ = try JSONSerialization.jsonObject(with: body)
        // The old model-blind decode remains unchanged for all other families.
        let legacy = try ProviderLoop.decodeOpenAIRequest(body)
        let other = try ProviderLoop.decodeOpenAIRequest(body, modelType: "llama")
        let nativeRequest = try ProviderLoop.decodeOpenAIRequest(body, modelType: "glm5_next")
        #expect(legacy.tools == other.tools)
        #expect(legacy.tools != nativeRequest.tools)
        let controls = ProviderLoop.extractChatTemplateControls(from: body)
        let native = try ProviderPromptContractPipeline.normalizedInput(
            prepared: ToolChoicePromptPolicy.prepare(legacy, modelType: "glm5_next"),
            request: legacy, modelType: "glm5_next", templateControls: controls)
        let tools = try #require(native.tools)
        let rendered = try Template("{{ tools | tojson(ensure_ascii=False) }}").render([
            "tools": try Jinja.Value(any: tools)
        ])
        #expect(rendered.contains(#""allow":true"#))
        #expect(rendered.contains(#""type":["boolean","null"]"#))
        #expect(rendered.contains(#""type":["integer","null"]"#))
        #expect(rendered.contains(#""type":["string","null"]"#))
        #expect(!rendered.contains("x-darkbloom-original-boolean-schema"))
    }

    @Test func forgedInternalMarkersFailOnlyAfterActualGLMIdentityIsSelected() throws {
        let body = Data(#"{"model":"not-a-native-grant","model_type":"glm5_next","messages":[{"role":"user","content":"Hi"}],"tools":[{"type":"function","function":{"name":"f","parameters":{"type":"object","properties":{"x":{"type":"string","x-darkbloom-original-boolean-schema":true}}}}}]}"#.utf8)
        let controls = ProviderLoop.extractChatTemplateControls(from: body)
        #expect(controls.rawGLM5Controls.invalid)
        #expect(throws: (any Error).self) {
            try ProviderLoop.decodeOpenAIRequest(body, modelType: "glm5_next")
        }
        #expect(throws: (any Error).self) {
            try ProviderPromptContractPipeline.validateNativeControls(controls, modelType: "glm5_next")
        }
        // Caller model_type is not authority; existing non-GLM decoding and
        // validation retain their old treatment of coordinator-owned markers.
        _ = try ProviderLoop.decodeOpenAIRequest(body, modelType: "llama")
        try ProviderPromptContractPipeline.validateNativeControls(controls, modelType: "llama")
        let propertyName = Data(#"{"model":"m","messages":[],"tools":[{"function":{"name":"f","parameters":{"type":"object","properties":{"x-darkbloom-original-boolean-schema":{"type":"string"}}}}}]}"#.utf8)
        #expect(!ProviderLoop.extractChatTemplateControls(from: propertyName).rawGLM5Controls.invalid)
    }

    @Test func responsesUsesTheSameCanonicalControlsAndRejectsMalformedAliases() throws {
        let body = Data(#"{"model":"m","input":"Hi","reasoning":{"effort":"high"},"clear_thinking":true}"#.utf8)
        let local = try JSONDecoder().decode(LocalResponseRequest.self, from: body)
        let chat = local.request.chatCompletionRequest
        let input = try ProviderPromptContractPipeline.normalizedInput(
            prepared: ToolChoicePromptPolicy.prepare(chat, modelType: "glm5_next"),
            request: chat, modelType: "glm5_next", templateControls: local.templateControls)
        #expect(input.additionalContext?["reasoning_effort"] as? String == "high")
        #expect(input.additionalContext?["clear_thinking"] as? Bool == true)
        let malformed = Data(#"{"model":"m","input":"Hi","reasoning":{"effort":"high"},"clear_thinking":"true"}"#.utf8)
        let invalid = try JSONDecoder().decode(LocalResponseRequest.self, from: malformed)
        #expect(throws: (any Error).self) {
            try ProviderPromptContractPipeline.validateNativeControls(invalid.templateControls, modelType: "glm5_next")
        }
        try ProviderPromptContractPipeline.validateNativeControls(invalid.templateControls, modelType: "llama")
        let disabled = try JSONDecoder().decode(LocalResponseRequest.self,
            from: Data(#"{"model":"m","input":"Hi","reasoning":{"effort":"none"}}"#.utf8))
        let disabledChat = disabled.request.chatCompletionRequest
        let thinkingOff = try ProviderPromptContractPipeline.normalizedInput(
            prepared: ToolChoicePromptPolicy.prepare(disabledChat, modelType: "glm5_next"),
            request: disabledChat, modelType: "glm5_next", templateControls: disabled.templateControls)
        #expect(thinkingOff.additionalContext?["enable_thinking"] as? Bool == false)
    }

    private static let returnedThought = "Boston needs the weather tool; call it in fahrenheit."

    /// OpenRouter's returned-reasoning turn: the weather tool its tests
    /// declare (closed schema, `strict` when asked), an assistant call with
    /// the `assistant` fields (its reasoning) merged in, and the tool result.
    /// `controls` is a JSON object merged into the request.
    private func returnedReasoningConversation(
        assistant fields: [String: Any], controls: String = "{}", strict: Bool = false
    ) throws -> Data {
        var assistant: [String: Any] = [
            "role": "assistant", "content": "",
            "tool_calls": [[
                "id": "call_weather", "type": "function",
                "function": ["name": "get_current_weather",
                             "arguments": #"{"location":"Boston, MA","unit":"fahrenheit"}"#],
            ]],
        ]
        assistant.merge(fields) { _, added in added }
        var function: [String: Any] = [
            "name": "get_current_weather", "description": "Get the current weather in a given location",
            "parameters": [
                "type": "object", "additionalProperties": false, "required": ["location", "unit"],
                "properties": [
                    "location": ["type": "string", "description": "The city and state, e.g. San Francisco, CA"],
                    "unit": ["type": "string", "enum": ["celsius", "fahrenheit"]],
                ],
            ] as [String: Any],
        ]
        if strict { function["strict"] = true }
        var body: [String: Any] = [
            "model": "glm-5.3-flash", "stream": true,
            "messages": [
                ["role": "user", "content": "What is the weather like in Boston, MA in fahrenheit?"],
                assistant,
                ["role": "tool", "tool_call_id": "call_weather", "content": #"{"temperature":72}"#],
            ],
            "tools": [["type": "function", "function": function]],
        ]
        let merged = try #require(JSONSerialization.jsonObject(with: Data(controls.utf8)) as? [String: Any])
        body.merge(merged) { _, added in added }
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// OpenRouter returns an earlier turn's reasoning as `reasoning` or
    /// `reasoning_details` (`reasoning_content` is its alias). Each renders
    /// exactly as `reasoning_content`, which the template keeps in history
    /// while `clear_thinking` is false. Summary and encrypted details carry no
    /// replayable text and are skipped.
    @Test func returnedAssistantReasoningRendersLikeReasoningContent() throws {
        let template = try shippedTemplate()
        let thought = Self.returnedThought
        let half = thought.index(thought.startIndex, offsetBy: 20)
        func text(_ value: String) -> [String: Any] {
            ["type": "reasoning.text", "text": value, "signature": NSNull(), "id": NSNull(), "format": "unknown"]
        }
        let opaque: [[String: Any]] = [
            ["type": "reasoning.summary", "summary": "Weather lookup.", "format": "anthropic-claude-v1", "index": 0],
            ["type": "reasoning.encrypted", "data": "ZW5jcnlwdGVk", "format": "anthropic-claude-v1", "index": 1],
        ]
        func rendered(_ reasoning: [String: Any]) throws -> [String] {
            try remoteAndLocalInputs(returnedReasoningConversation(assistant: reasoning)).map {
                try render($0, with: template)
            }
        }
        let expected = try rendered(["reasoning_content": thought])
        #expect(expected[0] == expected[1])
        #expect(expected[0].contains("<|assistant|><think>\(thought)</think><tool_call>get_current_weather"))
        for spelling: [String: Any] in [
            ["reasoning": thought],
            ["reasoning_details": [text(thought)]],
            ["reasoning_details": opaque + [text(String(thought[..<half])), text(String(thought[half...]))]],
            ["reasoning": thought, "reasoning_details": [text(thought)]],
            ["reasoning": "", "reasoning_details": [text(thought)]],
            ["content": NSNull(), "reasoning_details": [text(thought)]],
            ["reasoning_content": thought, "reasoning": "stale", "reasoning_details": [text("stale")]],
        ] {
            #expect(try rendered(spelling) == expected, "\(spelling.keys.sorted())")
        }
        // Without replayable text the turn keeps the template's empty block.
        let empty = try rendered([:])
        #expect(empty[0].contains("<|assistant|><think></think><tool_call>"))
        for spelling: [String: Any] in [
            ["reasoning_details": opaque], ["reasoning": NSNull(), "reasoning_details": NSNull()],
            ["reasoning": ["text": thought]], ["reasoning_details": "not a list"],
        ] {
            #expect(try rendered(spelling) == empty, "\(spelling.keys.sorted())")
        }
        // `clear_thinking` still drops it before the last user turn.
        var cleared = try #require(JSONSerialization.jsonObject(
            with: returnedReasoningConversation(assistant: ["reasoning": thought])) as? [String: Any])
        cleared["clear_thinking"] = true
        cleared["messages"] = (cleared["messages"] as? [Any] ?? []) + [["role": "user", "content": "Thanks"]]
        let clearedRender = try render(normalized(JSONSerialization.data(withJSONObject: cleared)), with: template)
        #expect(!clearedRender.contains(thought) && clearedRender.contains("<|assistant|><think></think><tool_call>"))
    }

    /// OpenRouter's `reasoning-content-return` request shapes: the returned
    /// tool turn with OpenRouter's reasoning fields, GLM's own API spelling of
    /// the thinking switch, or OpenRouter's `strict` weather tool. MiMo and
    /// Nemotron Super serve each. GLM served only the first and refused the
    /// others with `invalid_request` before rendering.
    @Test(arguments: [
        ("{}", false),
        (#"{"reasoning":null}"#, false),
        (#"{"reasoning":{"enabled":true,"effort":null,"max_tokens":null,"exclude":false}}"#, false),
        (#"{"reasoning":{"effort":"high","summary":"auto"}}"#, false),
        (#"{"reasoning":{"effort":"max","generate_summary":"detailed"}}"#, false),
        (#"{"include_reasoning":null}"#, false),
        (#"{"include_reasoning":true,"reasoning":{"enabled":true,"exclude":null}}"#, false),
        (#"{"thinking":{"type":"enabled","clear_thinking":false}}"#, false),
        (#"{"thinking":{"type":"enabled"}}"#, false),
        (#"{"thinking":true}"#, false),
        (#"{"thinking":null}"#, false),
        ("{}", true),
        (#"{"reasoning":{"enabled":true}}"#, true),
    ])
    func openRouterReasoningContentReturnRequestIsServed(controls: String, strict: Bool) throws {
        let template = try shippedTemplate()
        let body = try returnedReasoningConversation(
            assistant: ["reasoning_content": Self.returnedThought], controls: controls, strict: strict)
        let evidence = try JSONDecoder().decode(GLM5NextPromptPolicy.RawControls.self, from: body)
        #expect(!evidence.invalid && !evidence.disablesThinking && !evidence.excludesReasoning)
        for input in try remoteAndLocalInputs(body) {
            #expect(input.additionalContext?["enable_thinking"] == nil)
            #expect(input.additionalContext?["clear_thinking"] as? Bool == false)
            let rendered = try render(input, with: template)
            #expect(rendered.contains("<|assistant|><think>\(Self.returnedThought)</think><tool_call>"))
            #expect(rendered.hasSuffix(#"<tool_response>{"temperature":72}</tool_response><|assistant|><think>"#))
        }
    }

    /// A returned call without arguments (`""`) renders like `{}`, as MiMo,
    /// Nemotron Super and vLLM read it.
    @Test func emptyHistoryArgumentsRenderAsAnEmptyObject() throws {
        let template = try shippedTemplate()
        func rendered(_ arguments: String) throws -> [String] {
            try remoteAndLocalInputs(returnedReasoningConversation(assistant: [
                "reasoning_content": Self.returnedThought,
                "tool_calls": [["id": "call_weather", "type": "function",
                                "function": ["name": "get_current_weather", "arguments": arguments]]],
            ])).map { try render($0, with: template) }
        }
        let empty = try rendered("")
        #expect(try empty == rendered("{}"))
        #expect(empty[0].contains("</think><tool_call>get_current_weather</tool_call><|observation|>"))
    }

    /// GLM's API spells history clearing inside `thinking`; the top-level and
    /// template-kwargs spellings keep precedence.
    @Test func thinkingObjectClearThinkingYieldsToTheOtherSpellings() throws {
        func clear(_ controls: String) throws -> Bool? {
            let body = try returnedReasoningConversation(assistant: [:], controls: controls)
            let values = try remoteAndLocalInputs(body).map { $0.additionalContext?["clear_thinking"] as? Bool }
            #expect(Set(values).count == 1, "\(controls)")
            return values[0]
        }
        #expect(try clear(#"{"thinking":{"type":"enabled","clear_thinking":true}}"#) == true)
        #expect(try clear(#"{"thinking":{"clear_thinking":true},"clear_thinking":false}"#) == false)
        #expect(try clear(#"{"thinking":{"clear_thinking":true},"chat_template_kwargs":{"clear_thinking":false}}"#)
            == false)
    }

    /// OpenRouter's captured tool-test requests, byte for byte as the platform
    /// conformance fixtures hold them (`orIncidentOmitted` and `orIncidentAuto`
    /// in `coordinator/tests/internal/conformance/incident_fixtures.go`).
    private static let capturedOpenRouterToolOmitted = #"{"messages":[{"content":"What is the weather like in Boston, MA in fahrenheit?","role":"user"}],"reasoning":{"enabled":false},"stream":true,"tools":[{"function":{"description":"Get the current weather in a given location","name":"get_current_weather","parameters":{"additionalProperties":false,"properties":{"location":{"description":"The city and state, e.g. San Francisco, CA","type":"string"},"unit":{"enum":["celsius","fahrenheit"],"type":"string"}},"required":["location","unit"],"type":"object"},"strict":true},"type":"function"}]}"#
    private static let capturedOpenRouterToolAuto = #"{"messages":[{"content":"What is the weather like in Boston, MA in fahrenheit?","role":"user"}],"reasoning":{"enabled":false},"stream":true,"tool_choice":"auto","tools":[{"function":{"description":"Get the current weather in a given location","name":"get_current_weather","parameters":{"additionalProperties":false,"properties":{"location":{"description":"The city and state, e.g. San Francisco, CA","type":"string"},"unit":{"enum":["celsius","fahrenheit"],"type":"string"}},"required":["location","unit"],"type":"object"},"strict":true},"type":"function"}]}"#

    /// A captured body plus the routed `model` it lacks, as the platform
    /// fixture adds it; `fields` replace top-level members.
    private func capturedOpenRouterRequest(_ captured: String, replacing fields: [String: Any] = [:]) throws -> Data {
        var body = try #require(JSONSerialization.jsonObject(with: Data(captured.utf8)) as? [String: Any])
        body["model"] = "glm-5.3-flash"
        body.merge(fields) { _, replacement in replacement }
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// Both paths, including the serving tool-stream handler, to the shipped
    /// template. The captured requests turn thinking off.
    private func renderedThinkingOffToolRequest(_ body: Data) throws -> [String] {
        let (request, _) = try requestAndControls(body)
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: "glm5_next")
        _ = try ToolStreamPreparation.makeHandler(request: request, prepared: prepared, modelType: "glm5_next")
        let evidence = try JSONDecoder().decode(GLM5NextPromptPolicy.RawControls.self, from: body)
        #expect(!evidence.invalid && evidence.disablesThinking && !evidence.requestsThinking)
        let template = try shippedTemplate()
        return try remoteAndLocalInputs(body).map { input in
            #expect(input.additionalContext?["enable_thinking"] as? Bool == false)
            return try render(input, with: template)
        }
    }

    /// OpenRouter's `tool-choice-auto`, `tool-call-step-1` and `tool-choice-none`
    /// shapes: its captured `strict` weather tool with `tool_choice` omitted,
    /// `auto` and `none`. GLM refused each with `invalid_request`.
    @Test(arguments: ["omitted", "auto", "none"])
    func capturedOpenRouterToolRequestIsServed(toolChoice: String) throws {
        #expect(sha(Data(Self.capturedOpenRouterToolOmitted.utf8))
            == "f0f8f60c48d944fb9270c6facfd5cc0c5543fc37b48cce6ef847abe3be8f2150")
        #expect(sha(Data(Self.capturedOpenRouterToolAuto.utf8))
            == "d63598aad05a4e1dda12a82c119616c490de714f1a51328b39eb598b6229844b")
        let body = try toolChoice == "omitted"
            ? capturedOpenRouterRequest(Self.capturedOpenRouterToolOmitted)
            : capturedOpenRouterRequest(Self.capturedOpenRouterToolAuto,
                replacing: toolChoice == "none" ? ["tool_choice": "none"] : [:])
        for rendered in try renderedThinkingOffToolRequest(body) {
            #expect(rendered.hasSuffix("<|user|>What is the weather like in Boston, MA in fahrenheit?<|assistant|><think>"))
            #expect(!rendered.contains("strict"))
            if toolChoice == "none" {
                #expect(!rendered.contains("get_current_weather"))
                #expect(rendered.contains("Do not call any tool."))
            } else {
                // The declaration renders unchanged, closed schema included.
                #expect(rendered.contains(#"""
                    <tools>
                    {"description": "Get the current weather in a given location", "name": "get_current_weather", "parameters": {"additionalProperties":false,"properties":{"location":{"description":"The city and state, e.g. San Francisco, CA","type":"string"},"unit":{"enum":["celsius","fahrenheit"],"type":"string"}},"required":["location","unit"],"type":"object"}}
                    </tools>
                    """#))
            }
        }
    }

    /// OpenRouter's `tool-call-step-5` shape: the captured `strict` tool after
    /// five completed calls, two of which return their reasoning.
    @Test func capturedOpenRouterToolServesAFiveStepConversation() throws {
        var body = try #require(JSONSerialization.jsonObject(
            with: capturedOpenRouterRequest(Self.capturedOpenRouterToolAuto)) as? [String: Any])
        var messages = try #require(body["messages"] as? [[String: Any]])
        let cities = ["Boston, MA", "Cambridge, MA", "Providence, RI", "Hartford, CT", "Portland, ME"]
        for (step, city) in cities.enumerated() {
            let id = "call_step_\(step + 1)"
            var call: [String: Any] = [
                "role": "assistant", "content": NSNull(),
                "tool_calls": [["id": id, "type": "function", "function": [
                    "name": "get_current_weather",
                    "arguments": #"{"location":"\#(city)","unit":"fahrenheit"}"#,
                ]]],
            ]
            if !step.isMultiple(of: 2) { call["reasoning"] = "Next: \(cities[step])." }
            messages.append(call)
            messages.append(["role": "tool", "tool_call_id": id,
                             "content": #"{"temperature":\#(60 + step),"unit":"fahrenheit"}"#])
        }
        body["messages"] = messages
        for rendered in try renderedThinkingOffToolRequest(JSONSerialization.data(withJSONObject: body)) {
            #expect(rendered.components(separatedBy: "<tool_call>get_current_weather").count == 6)
            #expect(rendered.components(separatedBy: "<|observation|><tool_response>").count == 6)
            #expect(rendered.contains("<|assistant|><think>Next: Cambridge, MA.</think><tool_call>"))
            #expect(rendered.contains("<|assistant|><think>Next: Hartford, CT.</think><tool_call>"))
            #expect(rendered.hasSuffix(#"<tool_response>{"temperature":64,"unit":"fahrenheit"}</tool_response><|assistant|><think>"#))
        }
    }

    @Test func exactLargeSchemaNumbersArePreservedOrRejectedBeforeRounding() throws {
        let exact = Data(#"{"model":"m","messages":[],"tools":[{"function":{"name":"f","parameters":{"type":"object","properties":{"n":{"type":"integer","enum":[9223372036854775807]}}}}}]}"#.utf8)
        let input = try normalized(exact)
        let rendered = try Template("{{ tools | tojson(ensure_ascii=False) }}").render([
            "tools": try Jinja.Value(any: input.tools)
        ])
        #expect(rendered.contains("9223372036854775807"))
        let inexact = Data(#"{"model":"m","messages":[],"tools":[{"function":{"name":"f","parameters":{"type":"object","properties":{"n":{"type":"integer","enum":[18446744073709551615]}}}}}]}"#.utf8)
        #expect(throws: (any Error).self) { try normalized(inexact) }
    }
}

/// A tokenizer whose rendered generation prompt ends with an open `<think>`.
private struct ThinkFixtureTokenizer: MLXLMCommon.Tokenizer {
    static let open = 154_841
    static let close = 154_842
    static let prompt = [7, 8, open]
    var rendered = prompt
    var hasThinkTokens = true

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenIds.compactMap(convertIdToToken).joined()
    }
    func convertTokenToId(_ token: String) -> Int? {
        guard hasThinkTokens else { return nil }
        return token == "<think>" ? Self.open : token == "</think>" ? Self.close : nil
    }
    func convertIdToToken(_ id: Int) -> String? {
        id == Self.open ? "<think>" : id == Self.close ? "</think>" : nil
    }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] { rendered }
    func applyChatTemplate(
        messages: [[String: any Sendable]], chatTemplate: String,
        tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?
    ) throws -> [Int] { rendered }
}
