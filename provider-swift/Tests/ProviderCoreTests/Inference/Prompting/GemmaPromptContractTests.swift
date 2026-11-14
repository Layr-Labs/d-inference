import Foundation
import Jinja
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// Gemma 4 prompt contract 2 (the template's text parts, vLLM's prompt) renders
/// only for a coordinator request that asks for it; everything else renders
/// contract 1, as 0.10.12. Token-level vectors on the served artifacts:
/// `ProductionPromptParityTests.gemmaPromptContractVectors`.
@Suite("Gemma 4 prompt contract")
struct GemmaPromptContractTests {
    private static let system = "You are a helpful assistant."
    private static let question = "Answer the following multiple choice question.\n\nWhat is 2+2?\n\nA) 3\nB) 4"

    private static func body(_ messages: [[String: Any]], extra: [String: Any] = [:]) throws -> Data {
        var body: [String: Any] = ["model": "gemma-4-26b-qat-4bit", "reasoning": ["enabled": true],
                                   "messages": messages]
        body.merge(extra) { _, new in new }
        return try JSONSerialization.data(withJSONObject: body)
    }

    private static func input(
        _ body: Data, modelType: String? = "gemma4", contract: Int? = 2
    ) throws -> ProviderPromptContractPipeline.NormalizedInput {
        let request = try ProviderLoop.decodeOpenAIRequest(body)
        return try ProviderPromptContractPipeline.normalizedInput(
            prepared: ToolChoicePromptPolicy.prepare(request, modelType: modelType),
            request: request, modelType: modelType,
            templateControls: ProviderLoop.extractChatTemplateControls(from: body)
                .askingGemmaPromptContract(contract, enabled: true))
    }

    private static func texts(_ content: (any Sendable)?) -> [String]? {
        (content as? [any Sendable])?.map { item -> String in
            let entry = item as? [String: any Sendable]
            #expect(entry?["type"] as? String == "text")
            return entry?["text"] as? String ?? "<not text>"
        }
    }

    @Test func contract2RendersASystemStringAsOneTextPart() throws {
        let body = try Self.body([["role": "system", "content": Self.system],
                                  ["role": "user", "content": Self.question]])
        let messages = try Self.input(body).messages
        #expect(Self.texts(messages[0]["content"]) == [Self.system])
        #expect(messages[1]["content"] as? String == Self.question)
        let developer = try Self.body([["role": "developer", "content": Self.system],
                                       ["role": "user", "content": Self.question]])
        let developerMessages = try Self.input(developer).messages
        #expect(Self.texts(developerMessages[0]["content"]) == [Self.system])
        // Contract 1: the string, as 0.10.12.
        #expect(try Self.input(body, contract: nil).messages[0]["content"] as? String == Self.system)
    }

    @Test func contract2KeepsListShapedSystemAndUserTextParts() throws {
        let body = try Self.body([
            ["role": "system", "content": [["type": "text", "text": "You are a helpful assistant. "],
                                           ["type": "input_text", "text": "\nAnswer briefly."]]],
            ["role": "user", "content": [["type": "text", "text": "What is 2+2? "],
                                         ["type": "text", "text": " Reply with a digit.\n"]]],
        ])
        let messages = try Self.input(body).messages
        #expect(Self.texts(messages[0]["content"]) == ["You are a helpful assistant. ", "\nAnswer briefly."])
        #expect(Self.texts(messages[1]["content"]) == ["What is 2+2? ", " Reply with a digit.\n"])
        let contract1 = try Self.input(body, contract: nil).messages
        #expect(contract1[0]["content"] as? String == "You are a helpful assistant. \nAnswer briefly.")
        #expect(contract1[1]["content"] as? String == "What is 2+2?  Reply with a digit.\n")
    }

    @Test func requestsWithoutASystemMessageOrListContentRenderAlike() throws {
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
        let contract2 = try Self.input(body).messages
        let contract1 = try Self.input(body, contract: nil).messages
        #expect(contract2.count == contract1.count)
        for (left, right) in zip(contract2, contract1) {
            #expect(left["role"] as? String == right["role"] as? String)
            #expect(left["content"] is String)
            #expect(left["content"] as? String == right["content"] as? String)
        }
    }

    @Test func onlyAnAskingCoordinatorRequestRendersContract2() throws {
        let body = try Self.body([["role": "system", "content": Self.system],
                                  ["role": "user", "content": Self.question]])
        let request = try ProviderLoop.decodeOpenAIRequest(body)
        let plain = ChatTemplateControls()
        #expect(plain.gemmaPromptContract == nil)
        #expect(plain.askingGemmaPromptContract(nil, enabled: true) == plain)
        #expect(plain.askingGemmaPromptContract(1, enabled: true) == plain)
        #expect(plain.askingGemmaPromptContract(3, enabled: true) == plain)
        #expect(plain.askingGemmaPromptContract(2, enabled: false) == plain)
        let asked = plain.askingGemmaPromptContract(2, enabled: true)
        #expect(asked.gemmaPromptContract == 2)
        // A planned request asks for the contract its plan was made with.
        #expect(plain.servingCoordinatorRequest(planned: true)
            .askingGemmaPromptContract(2, enabled: true).gemmaPromptContract == 2)
        #expect(GemmaPromptContract.rendersParts(request, modelType: "gemma4", controls: asked))
        #expect(GemmaPromptContract.rendersParts(request, modelType: "gemma4_text", controls: asked))
        #expect(!GemmaPromptContract.rendersParts(request, modelType: "gemma4", controls: plain))
        #expect(!GemmaPromptContract.rendersParts(request, modelType: "diffusion_gemma", controls: asked))
        #expect(!GemmaPromptContract.rendersParts(request, modelType: "qwen3_5", controls: asked))
        #expect(!GemmaPromptContract.rendersParts(request, modelType: nil, controls: asked))
        #expect(try Self.input(body, modelType: "qwen3_5").messages[0]["content"] as? String == Self.system)
        let media = try ProviderLoop.decodeOpenAIRequest(Self.body([
            ["role": "system", "content": Self.system],
            ["role": "user", "content": [["type": "text", "text": "What is this?"],
                                         ["type": "image_url", "image_url": ["url": "data:image/png;base64,AAAA"]]]],
        ]))
        #expect(!GemmaPromptContract.rendersParts(media, modelType: "gemma4", controls: asked))
    }

    /// The handler renders a coordinator request with exactly these controls.
    @Test func aCoordinatorRequestRendersTheContractItsFrameAsksFor() throws {
        let body = try Self.body([["role": "system", "content": Self.system],
                                  ["role": "user", "content": Self.question]])
        let controls = ProviderLoop.extractChatTemplateControls(from: body)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for planned in [false, true] {
            let asked = controls.servingCoordinatorRequest(
                planned: planned, gemmaPromptContract: 2, enabled: true, at: now)
            #expect(asked.gemmaPromptContract == 2)
            #expect(asked == controls.servingCoordinatorRequest(planned: planned)
                .askingGemmaPromptContract(2, enabled: true).resolvingPromptDate(at: now))
            for version in [nil, 1, 3] as [Int?] {
                #expect(controls.servingCoordinatorRequest(
                    planned: planned, gemmaPromptContract: version, enabled: true, at: now).gemmaPromptContract == nil)
            }
            #expect(controls.servingCoordinatorRequest(
                planned: planned, gemmaPromptContract: 2, enabled: false, at: now).gemmaPromptContract == nil)
        }
        let request = try ProviderLoop.decodeOpenAIRequest(body)
        let served = try ProviderPromptContractPipeline.normalizedInput(
            prepared: ToolChoicePromptPolicy.prepare(request, modelType: "gemma4"), request: request,
            modelType: "gemma4", templateControls: controls.servingCoordinatorRequest(
                planned: true, gemmaPromptContract: 2, enabled: true, at: now)).messages
        #expect(Self.texts(served[0]["content"]) == [Self.system])
    }

    @Test func emptyMissingAndOtherRolesFollowVLLM() throws {
        let empty = try #require(GemmaPromptContract.textParts(of: OpenAIChatMessage(role: .system, content: .text(""))))
        #expect(Self.texts(empty) == [""])
        #expect(GemmaPromptContract.textParts(of: OpenAIChatMessage(role: .system, content: .null)) == nil)
        #expect(GemmaPromptContract.textParts(of: OpenAIChatMessage(role: .system, content: .parts([]))) == nil)
        #expect(GemmaPromptContract.textParts(of: OpenAIChatMessage(role: .user, content: .text("hi"))) == nil)
        #expect(GemmaPromptContract.textParts(of: OpenAIChatMessage(role: .assistant, content: .parts([.text("a")]))) == nil)
        #expect(GemmaPromptContract.textParts(of: OpenAIChatMessage(role: .tool, content: .parts([.text("a")]))) == nil)
    }

    @Test func theUsageFloorCountsThePromptTheEngineServes() throws {
        let body = try Self.body([["role": "system", "content": Self.system],
                                  ["role": "user", "content": Self.question]])
        let request = try ProviderLoop.decodeOpenAIRequest(body)
        let contract1 = ProviderLoop.extractChatTemplateControls(from: body)
        let contract2 = contract1.askingGemmaPromptContract(2, enabled: true)
        func floor(_ controls: ChatTemplateControls) -> Int {
            ProviderLoop.promptTokenFloor(request: request, tokenizer: TokenizerHandle(PartsCountingTokenizer()),
                modelType: "gemma4", templateControls: controls)
        }
        func served(_ controls: ChatTemplateControls) throws -> Int {
            try ProviderPromptContractPipeline.tokenize(
                prepared: ToolChoicePromptPolicy.prepare(request, modelType: "gemma4"), request: request,
                tokenizer: PartsCountingTokenizer(), modelType: "gemma4", templateControls: controls).count
        }
        #expect(floor(contract2) == 3)
        #expect(try served(contract2) == 3)
        #expect(floor(contract1) == 2)
        #expect(try served(contract1) == 2)
    }

    @Test func theSwitchIsOnUnlessTurnedOffAndDecidesTheAdvertisement() {
        for value in [nil, "", "on", "1", "true", "yes"] {
            #expect(GemmaPromptContract.isEnabled(value), "\(value ?? "nil")")
        }
        for value in ["off", "0", "false", "no", " OFF ", "False"] {
            #expect(!GemmaPromptContract.isEnabled(value), "\(value)")
        }
        #expect(GemmaPromptContract.advertisedVersion(enabled: true) == 2)
        #expect(GemmaPromptContract.advertisedVersion(enabled: false) == nil)
    }

    @Test func theSwitchReachesTheLaunchdJob() {
        let key = GemmaPromptContract.environmentKey
        #expect(key == "DARKBLOOM_GEMMA_PROMPT_CONTRACT_V2")
        #expect(LaunchAgent.passthroughEnvironment(from: [key: "off"])[key] == "off")
        #expect(LaunchAgent.passthroughEnvironment(from: [:])[key] == nil)
    }

    @Test func theRegistrationAdvertisesContract2() throws {
        func registration(_ version: Int?) throws -> [String: Any] {
            let message = ProviderMessage.register(.init(
                hardware: HardwareInfo(machineModel: "fixture", chipName: "Apple M3 Ultra", chipFamily: .m3,
                    chipTier: .ultra, memoryGb: 256, memoryAvailableGb: 240,
                    cpuCores: .init(total: 32, performance: 24, efficiency: 8), gpuCores: 80,
                    memoryBandwidthGbs: 819),
                models: [], backend: "mlx-swift", gemmaPromptContract: version))
            let data = try ProviderProtocolCodec.encodeProviderMessage(message)
            guard case .register(let decoded) = try ProviderProtocolCodec.decodeProviderMessage(from: data) else {
                Issue.record("not a register frame"); return [:]
            }
            #expect(decoded.gemmaPromptContract == (version.map { $0 > 1 ? $0 : nil } ?? nil))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(try registration(2)["gemma_prompt_contract"] as? Int == 2)
        #expect(try registration(nil)["gemma_prompt_contract"] == nil)
        #expect(try registration(1)["gemma_prompt_contract"] == nil)
    }

    @Test func anInferenceRequestCarriesTheContractAndAMalformedOneKeepsTheFrame() throws {
        let frame = CoordinatorMessage.inferenceRequest(.init(requestId: "r", gemmaPromptContract: 2))
        let encoded = try JSONEncoder().encode(frame)
        #expect(try JSONDecoder().decode(CoordinatorMessage.self, from: encoded) == frame)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["gemma_prompt_contract"] as? Int == 2)
        for (json, expected) in [
            (#"{"type":"inference_request","request_id":"r","gemma_prompt_contract":2}"#, 2),
            (#"{"type":"inference_request","request_id":"r"}"#, nil),
            (#"{"type":"inference_request","request_id":"r","gemma_prompt_contract":"two"}"#, nil),
            (#"{"type":"inference_request","request_id":"r","gemma_prompt_contract":null}"#, nil),
        ] as [(String, Int?)] {
            guard case .inferenceRequest(let request) = try JSONDecoder().decode(
                CoordinatorMessage.self, from: Data(json.utf8)) else {
                Issue.record("wrong frame"); continue
            }
            #expect(request.requestId == "r")
            #expect(request.gemmaPromptContract == expected, "\(json)")
        }
    }

    /// The served template's system block (lines 179–204 of
    /// `gemma-4-26b-qat-4bit`'s template 94899c0f…, verbatim): contract 2
    /// renders vLLM's trailing space, contract 1 the string.
    @Test func theServedSystemBlockRendersVLLMsSpaceForContract2() throws {
        let body = try Self.body([["role": "system", "content": Self.system],
                                  ["role": "user", "content": Self.question]])
        func render(contract: Int?) throws -> String {
            let messages = try Self.input(body, contract: contract).messages
            let template = try Template(Self.servedSystemBlock, with: .init(lstripBlocks: true, trimBlocks: true))
            return try template.render([
                "messages": .array(try messages.map { try Value(any: $0) }),
                "enable_thinking": .boolean(true),
            ])
        }
        #expect(try render(contract: 2) == "<|turn>system\n<|think|>\nYou are a helpful assistant. <turn|>\n")
        #expect(try render(contract: nil) == "<|turn>system\n<|think|>\nYou are a helpful assistant.<turn|>\n")
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
