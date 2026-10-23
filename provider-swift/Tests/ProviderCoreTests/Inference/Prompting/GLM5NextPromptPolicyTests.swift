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
        let malformed = Data(#"{"model":"m","messages":[],"reasoning":{"enabled":false,"summary":"auto"}}"#.utf8)
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
            ["include_reasoning": "true"], ["include_reasoning": NSNull()],
            ["preserve_thinking": true], ["thinking": true], ["thinking": ["type": "enabled"]],
            ["reasoning": NSNull()], ["reasoning": ["enabled": 1]], ["reasoning": ["exclude": "false"]],
            ["reasoning": ["max_tokens": 0]], ["reasoning": ["max_tokens": -1]],
            ["reasoning": ["max_tokens": 1.5]], ["reasoning": ["max_tokens": "1024"]],
            ["reasoning": ["max_tokens": NSNull()]], ["reasoning": ["summary": "auto"]],
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
