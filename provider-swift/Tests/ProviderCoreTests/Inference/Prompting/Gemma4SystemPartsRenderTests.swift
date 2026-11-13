import Foundation
import Jinja
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// Gemma 4 renders a system message, and a list-shaped user message, as the
/// template's text parts (vLLM's prompt) unless the coordinator planned the
/// request for its prompt cache. Token-level parity with vLLM on the served
/// artifacts: `ProductionPromptParityTests.gemmaSystemPartsVectors`.
@Suite("Gemma 4 system parts render")
struct Gemma4SystemPartsRenderTests {
    private static let system = "You are a helpful assistant."
    private static let question = "Answer the following multiple choice question.\n\nWhat is 2+2?\n\nA) 3\nB) 4"

    private static func body(_ messages: [[String: Any]], extra: [String: Any] = [:]) throws -> Data {
        var body: [String: Any] = ["model": "gemma-4-26b-qat-4bit", "reasoning": ["enabled": true],
                                   "messages": messages]
        body.merge(extra) { _, new in new }
        return try JSONSerialization.data(withJSONObject: body)
    }

    private static func input(
        _ body: Data, modelType: String? = "gemma4", planned: Bool = false
    ) throws -> ProviderPromptContractPipeline.NormalizedInput {
        let request = try ProviderLoop.decodeOpenAIRequest(body)
        return try ProviderPromptContractPipeline.normalizedInput(
            prepared: ToolChoicePromptPolicy.prepare(request, modelType: modelType),
            request: request, modelType: modelType,
            templateControls: ProviderLoop.extractChatTemplateControls(from: body)
                .servingCoordinatorRequest(planned: planned))
    }

    private static func texts(_ content: (any Sendable)?) -> [String]? {
        (content as? [any Sendable])?.map { item -> String in
            let entry = item as? [String: any Sendable]
            #expect(entry?["type"] as? String == "text")
            return entry?["text"] as? String ?? "<not text>"
        }
    }

    @Test func aStringSystemMessageBecomesOneTextPart() throws {
        let body = try Self.body([["role": "system", "content": Self.system],
                                  ["role": "user", "content": Self.question]])
        let messages = try Self.input(body).messages
        #expect(Self.texts(messages[0]["content"]) == [Self.system])
        #expect(messages[1]["content"] as? String == Self.question)
        let developer = try Self.body([["role": "developer", "content": Self.system],
                                       ["role": "user", "content": Self.question]])
        #expect(Self.texts(try Self.input(developer).messages[0]["content"]) == [Self.system])
    }

    @Test func listShapedSystemAndUserContentKeepTheirTextParts() throws {
        let body = try Self.body([
            ["role": "system", "content": [["type": "text", "text": "You are a helpful assistant. "],
                                           ["type": "input_text", "text": "\nAnswer briefly."]]],
            ["role": "user", "content": [["type": "text", "text": "What is 2+2? "],
                                         ["type": "text", "text": " Reply with a digit.\n"]]],
        ])
        let messages = try Self.input(body).messages
        #expect(Self.texts(messages[0]["content"]) == ["You are a helpful assistant. ", "\nAnswer briefly."])
        #expect(Self.texts(messages[1]["content"]) == ["What is 2+2? ", " Reply with a digit.\n"])
        // Planned: 0.10.12's joined string, the sidecar's plan.
        let planned = try Self.input(body, planned: true).messages
        #expect(planned[0]["content"] as? String == "You are a helpful assistant. \nAnswer briefly.")
        #expect(planned[1]["content"] as? String == "What is 2+2?  Reply with a digit.\n")
    }

    @Test func requestsWithoutASystemMessageOrListContentRenderAsBefore() throws {
        let body = try Self.body([
            ["role": "user", "content": "What is the weather in Paris?"],
            ["role": "assistant", "content": NSNull(), "tool_calls": [[
                "id": "call_1", "type": "function",
                "function": ["name": "get_weather", "arguments": "{\"city\": \"Paris\"}"]]]],
            ["role": "tool", "tool_call_id": "call_1", "content": "{\"temperature_c\": 18}"],
            ["role": "assistant", "content": "It is 18 °C."],
            ["role": "user", "content": "Thanks."],
        ], extra: ["tools": [["type": "function", "function": [
            "name": "get_weather", "description": "Weather for a city.",
            "parameters": ["type": "object", "properties": ["city": ["type": "string"]]]]]]])
        let unplanned = try Self.input(body).messages
        let planned = try Self.input(body, planned: true).messages
        #expect(unplanned.count == planned.count)
        for (left, right) in zip(unplanned, planned) {
            #expect(left["role"] as? String == right["role"] as? String)
            #expect(left["content"] is String)
            #expect(left["content"] as? String == right["content"] as? String)
        }
    }

    @Test func plannedRequestsTheSwitchMediaAndOtherFamiliesRenderAsBefore() throws {
        let body = try Self.body([["role": "system", "content": Self.system],
                                  ["role": "user", "content": Self.question]])
        #expect(try Self.input(body, planned: true).messages[0]["content"] as? String == Self.system)
        #expect(try Self.input(body, modelType: "qwen3_5").messages[0]["content"] as? String == Self.system)
        #expect(try Self.input(body, modelType: nil).messages[0]["content"] as? String == Self.system)

        let request = try ProviderLoop.decodeOpenAIRequest(body)
        let controls = ChatTemplateControls()
        #expect(Gemma4SystemPartsRender.applies(to: request, modelType: "gemma4", controls: controls, enabled: true))
        #expect(Gemma4SystemPartsRender.applies(to: request, modelType: "gemma4_text", controls: controls, enabled: true))
        #expect(!Gemma4SystemPartsRender.applies(to: request, modelType: "gemma4", controls: controls, enabled: false))
        #expect(!Gemma4SystemPartsRender.applies(to: request, modelType: "gemma4",
            controls: controls.servingCoordinatorRequest(planned: true), enabled: true))
        #expect(!Gemma4SystemPartsRender.applies(to: request, modelType: "diffusion_gemma", controls: controls, enabled: true))
        let media = try ProviderLoop.decodeOpenAIRequest(Self.body([
            ["role": "system", "content": Self.system],
            ["role": "user", "content": [["type": "text", "text": "What is this?"],
                                         ["type": "image_url", "image_url": ["url": "data:image/png;base64,AAAA"]]]],
        ]))
        #expect(!Gemma4SystemPartsRender.applies(to: media, modelType: "gemma4", controls: controls, enabled: true))
    }

    @Test func plannedOrCountedRequestsRenderTheCoordinatorsPrompt() throws {
        let controls = ChatTemplateControls(enableThinking: true)
        #expect(controls.servingCoordinatorRequest(planned: false) == controls)
        #expect(controls.servingCoordinatorRequest(planned: false, counted: false) == controls)
        #expect(!controls.rendersCoordinatorPrompt)
        #expect(controls.servingCoordinatorRequest(planned: true).rendersCoordinatorPrompt)
        #expect(controls.servingCoordinatorRequest(planned: false, counted: true).rendersCoordinatorPrompt)
        #expect(controls.servingCoordinatorRequest(planned: true).enableThinking == true)
        let body = try Self.body([["role": "system", "content": Self.system],
                                  ["role": "user", "content": Self.question]])
        let request = try ProviderLoop.decodeOpenAIRequest(body)
        #expect(!Gemma4SystemPartsRender.applies(to: request, modelType: "gemma4",
            controls: controls.servingCoordinatorRequest(planned: false, counted: true), enabled: true))
    }

    @Test func emptyMissingAndOtherRolesFollowVLLM() throws {
        let empty = try #require(Gemma4SystemPartsRender.textParts(of: OpenAIChatMessage(role: .system, content: .text(""))))
        #expect(Self.texts(empty) == [""])
        #expect(Gemma4SystemPartsRender.textParts(of: OpenAIChatMessage(role: .system, content: .null)) == nil)
        #expect(Gemma4SystemPartsRender.textParts(of: OpenAIChatMessage(role: .system, content: .parts([]))) == nil)
        #expect(Gemma4SystemPartsRender.textParts(of: OpenAIChatMessage(role: .user, content: .text("hi"))) == nil)
        #expect(Gemma4SystemPartsRender.textParts(of: OpenAIChatMessage(role: .assistant, content: .parts([.text("a")]))) == nil)
        #expect(Gemma4SystemPartsRender.textParts(of: OpenAIChatMessage(role: .tool, content: .parts([.text("a")]))) == nil)
    }

    @Test func theUsageFloorCountsThePromptTheEngineServes() throws {
        let body = try Self.body([["role": "system", "content": Self.system],
                                  ["role": "user", "content": Self.question]])
        let request = try ProviderLoop.decodeOpenAIRequest(body)
        let unplanned = ProviderLoop.extractChatTemplateControls(from: body)
        let planned = unplanned.servingCoordinatorRequest(planned: true)
        func floor(_ controls: ChatTemplateControls) -> Int {
            ProviderLoop.promptTokenFloor(request: request, tokenizer: TokenizerHandle(PartsCountingTokenizer()),
                modelType: "gemma4", templateControls: controls)
        }
        func served(_ controls: ChatTemplateControls) throws -> Int {
            try ProviderPromptContractPipeline.tokenize(
                prepared: ToolChoicePromptPolicy.prepare(request, modelType: "gemma4"), request: request,
                tokenizer: PartsCountingTokenizer(), modelType: "gemma4", templateControls: controls).count
        }
        #expect(floor(unplanned) == 3)
        #expect(try served(unplanned) == 3)
        #expect(floor(planned) == 2)
        #expect(try served(planned) == 2)
    }

    @Test func theSwitchIsOnUnlessTurnedOff() {
        for value in [nil, "", "on", "1", "true", "yes"] {
            #expect(Gemma4SystemPartsRender.isEnabled(value), "\(value ?? "nil")")
        }
        for value in ["off", "0", "false", "no", " OFF ", "False"] {
            #expect(!Gemma4SystemPartsRender.isEnabled(value), "\(value)")
        }
    }

    @Test func theSwitchReachesTheLaunchdJob() {
        let key = Gemma4SystemPartsRender.environmentKey
        #expect(key == "DARKBLOOM_GEMMA_SYSTEM_PARTS_RENDER")
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "off"])[key] == "off")
        #expect(LaunchAgent.passthroughEnvironment(from: [:])[key] == nil)
    }

    /// The served template's system block (lines 179–204 of
    /// `gemma-4-26b-qat-4bit`'s template 94899c0f…, verbatim) renders the
    /// parts with vLLM's trailing space and the string without it.
    @Test func theServedSystemBlockRendersVLLMsSpace() throws {
        let body = try Self.body([["role": "system", "content": Self.system],
                                  ["role": "user", "content": Self.question]])
        func render(planned: Bool) throws -> String {
            let messages = try Self.input(body, planned: planned).messages
            let template = try Template(Self.servedSystemBlock, with: .init(lstripBlocks: true, trimBlocks: true))
            return try template.render([
                "messages": .array(try messages.map { try Value(any: $0) }),
                "enable_thinking": .boolean(true),
            ])
        }
        #expect(try render(planned: false) == "<|turn>system\n<|think|>\nYou are a helpful assistant. <turn|>\n")
        #expect(try render(planned: true) == "<|turn>system\n<|think|>\nYou are a helpful assistant.<turn|>\n")
    }

    private static let servedSystemBlock = #"""
{%- set ns = namespace(prev_message_type=None) -%}
{%- if (enable_thinking is defined and enable_thinking) or tools or messages[0]['role'] in ['system', 'developer'] -%}
    {{- '<|turn>system\n' -}}
    {#- Inject Thinking token at the very top of the FIRST system turn -#}
    {%- if enable_thinking is defined and enable_thinking -%}
        {{- '<|think|>\n' -}}
        {%- set ns.prev_message_type = 'think' -%}
    {%- endif -%}
    {%- if messages[0]['role'] in ['system', 'developer'] -%}
        {%- if messages[0]['content'] is string -%}
            {{- messages[0]['content'] | trim -}}
        {%- elif messages[0]['content'] is sequence -%}
            {%- for item in messages[0]['content'] -%}
                {{- item['text'] | trim + ' '-}}
            {%- endfor -%}
        {%- endif -%}
        {%- set loop_messages = messages[1:] -%}
    {%- endif -%}
    {{- '<turn|>\n' -}}
{%- endif %}
"""#
}

/// One token per message, plus one per text part of list content.
private struct PartsCountingTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?) throws -> [Int] {
        let count = messages.reduce(0) { $0 + 1 + (($1["content"] as? [any Sendable])?.count ?? 0) }
        return Array(repeating: 7, count: count)
    }
}
