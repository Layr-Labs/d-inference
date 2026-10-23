// Copyright © 2026 Eigen Labs.
//
// OpenRouter capability requests on GLM-5.3-Flash through the production
// scheduler and OpenAI service: the shipped chat template rendered by
// Swift-Jinja, the serving thinking tokenizer and a scripted CBv2 engine in
// place of the model. No weights or GPU; what the model says is scripted, what
// the provider renders, withholds, validates and exposes is real.

import Foundation
import Jinja
import MLXLMCommon
import MLXLMServer
import ProviderCoreFoundation
import Testing

@testable import ProviderCore

/// Renders the shipped GLM template; one token per scalar, one per marker.
private struct GLMTemplateTokenizer: MLXLMCommon.Tokenizer {
    static let markers: [String: Int] = [
        "<|endoftext|>": 154820, "[gMASK]": 154822, "<sop>": 154824, "<|system|>": 154826,
        "<|user|>": 154827, "<|assistant|>": 154828, "<|observation|>": 154829,
        "<think>": 154841, "</think>": 154842, "<tool_call>": 154843, "</tool_call>": 154844,
        "<arg_key>": 154847, "</arg_key>": 154848, "<arg_value>": 154849, "</arg_value>": 154850,
    ]
    let template: Template
    let rendered: PromptCapture

    var bosToken: String? { nil }
    var eosToken: String? { "<|endoftext|>" }
    var unknownToken: String? { nil }
    func convertTokenToId(_ token: String) -> Int? { Self.markers[token] }
    func convertIdToToken(_ id: Int) -> String? { Self.markers.first { $0.value == id }?.key }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        var ids: [Int] = []
        var rest = Substring(text)
        while let first = rest.first {
            if let marker = Self.markers.keys.first(where: { rest.hasPrefix($0) }) {
                ids.append(Self.markers[marker]!)
                rest = rest.dropFirst(marker.count)
            } else {
                ids.append(contentsOf: String(first).unicodeScalars.map { Int($0.value) })
                rest = rest.dropFirst()
            }
        }
        return ids
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenIds.map { id in convertIdToToken(id) ?? Unicode.Scalar(id).map { String($0) } ?? "" }.joined()
    }

    func applyChatTemplate(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        var values: [String: Jinja.Value] = [
            "messages": try .init(any: messages), "add_generation_prompt": .boolean(true),
        ]
        if let tools { values["tools"] = try .init(any: tools) }
        for (key, value) in additionalContext ?? [:] { values[key] = try .init(any: value) }
        let prompt = try template.render(values)
        rendered.record(prompt)
        return encode(text: prompt, addSpecialTokens: false)
    }
}

private final class PromptCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var prompts: [String] { lock.withLock { values } }
    func record(_ prompt: String) { lock.withLock { values.append(prompt) } }
}

/// The model: one scripted completion per request, then a stop token.
private final class ScriptedGLMEngine: CBv2Engine, @unchecked Sendable {
    let output: [String]
    let finish: CBv2FinishReason
    init(output: [String], finish: CBv2FinishReason = .stop) {
        self.output = output
        self.finish = finish
    }
    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        for (index, text) in output.enumerated() {
            continuation.yield(.delta(text: text, tokens: [1000 + index], logprobs: nil))
        }
        continuation.yield(.finished(reason: finish,
            usage: CBv2Usage(promptTokens: request.promptTokens.count, completionTokens: output.count)))
        continuation.finish()
        return stream
    }
    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        CBv2CapacitySnapshot(activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0,
            kvBytesCapacity: 0, activeTokens: 0)
    }
    func shutdown() async {}
}

/// One served response as an OpenAI client reassembles its SSE frames.
private struct ServedResponse {
    var content = ""
    var reasoning = ""
    var toolCalls: [(name: String, arguments: String)] = []
    var finishReason: String?
    /// Delta kinds in arrival order ("reasoning", "content", "tool").
    var order: [String] = []
    var error: (any Error)?
    /// When the provider first recorded generated but withheld output.
    var firstWithheldOutputAt: ContinuousClock.Instant?
}

@Suite("GLM-5.3-Flash OpenRouter capability requests")
struct GLM5NextOpenRouterCapabilityTests {
    static let model = "glm-5.3-flash"
    /// The schema of `m5-proof/or_proof.py` `JSON_SCHEMA` (structured outputs).
    static var weatherReportSchema: [String: Any] { [
        "type": "object", "additionalProperties": false,
        "required": ["city", "temperature_f", "conditions"],
        "properties": [
            "city": ["type": "string"], "temperature_f": ["type": "integer"],
            "conditions": ["type": "string", "enum": ["sunny", "cloudy", "rain", "snow", "windy"]],
        ] as [String: Any],
    ] }
    static let austin = #"{"city":"Austin","temperature_f":75,"conditions":"sunny"}"#

    private static func shippedTemplate() throws -> Template {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let source = try String(contentsOf: root.appendingPathComponent(
            "fixtures/prompt-contract/glm53-flash/eigenlabs-chat_template.jinja"), encoding: .utf8)
        let served = NemotronTemplateFilters.bindingFilters(
            in: normalizeSwiftJinjaTemplate(source), modelType: "glm5_next")
        return try Template(served, with: .init(lstripBlocks: true, trimBlocks: true))
    }

    static func jsonObjectBody() -> [String: Any] {
        ["model": model, "stream": true, "max_tokens": 2048, "response_format": ["type": "json_object"],
         "messages": [["role": "user", "content":
            "Return a JSON object with keys city, temperature_f and conditions for a sunny 75F day in Austin."]]]
    }

    static func jsonSchemaBody() -> [String: Any] {
        ["model": model, "stream": true, "max_tokens": 2048,
         "response_format": ["type": "json_schema", "json_schema": [
            "name": "weather_report", "strict": true, "schema": weatherReportSchema] as [String: Any]],
         "messages": [["role": "user", "content": "Report the weather for a sunny 75F day in Austin."]]]
    }

    /// Serve `body` as the coordinator relay does: the provider decode, the
    /// model's reasoning parser, a forced stream, the OpenAI service and the
    /// scheduler over a GLM slot whose model says `output`.
    fileprivate func serve(_ body: [String: Any], output: [String], finish: CBv2FinishReason = .stop,
               prompts: PromptCapture = PromptCapture()) async throws -> ServedResponse {
        let data = try JSONSerialization.data(withJSONObject: body)
        var request = try ProviderLoop.decodeOpenAIRequest(data, modelType: "glm5_next")
        request.reasoningParser = ProviderLoop.inferReasoningParser(for: "glm5_next")
        request.stream = true
        let controls = ProviderLoop.extractChatTemplateControls(from: data)
        let tokenizer = TokenizerHandle(try GLM5NextThinkingTokenizer(
            base: GLMTemplateTokenizer(template: try Self.shippedTemplate(), rendered: prompts)))
        let bridge = EngineV2Bridge(engine: ScriptedGLMEngine(output: output, finish: finish),
            modelId: Self.model, tokenizer: tokenizer, eosTokenIds: [154820, 154827, 154829],
            kvBytesPerToken: 0)
        let usage = EngineV2RequestUsageSignal()
        let scheduler = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [Self.model: .init(tokenizer: tokenizer, modelType: "glm5_next", engineV2Bridge: bridge)]
            },
            defaultMaxTokens: 2048, templateControls: controls, engineV2Usage: usage)
        var served = ServedResponse()
        do {
            for try await frame in try await MLXOpenAIService(engine: scheduler)
                .streamChatCompletionFrames(request: request)
            {
                guard frame.hasPrefix("data: {"),
                    let chunk = try JSONSerialization.jsonObject(
                        with: Data(frame.dropFirst(6).utf8)) as? [String: Any],
                    let choice = (chunk["choices"] as? [[String: Any]])?.first
                else { continue }
                let delta = choice["delta"] as? [String: Any] ?? [:]
                if let text = delta["reasoning_content"] as? String, !text.isEmpty {
                    served.reasoning += text
                    served.order.append("reasoning")
                }
                if let text = delta["content"] as? String, !text.isEmpty {
                    served.content += text
                    served.order.append("content")
                }
                for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                    let function = call["function"] as? [String: Any] ?? [:]
                    if let name = function["name"] as? String {
                        served.toolCalls.append((name, function["arguments"] as? String ?? ""))
                    } else if let fragment = function["arguments"] as? String, !served.toolCalls.isEmpty {
                        served.toolCalls[served.toolCalls.count - 1].arguments += fragment
                    }
                    served.order.append("tool")
                }
                if let reason = choice["finish_reason"] as? String { served.finishReason = reason }
            }
        } catch {
            served.error = error
        }
        served.firstWithheldOutputAt = usage.firstWithheldOutputAt
        return served
    }

    // MARK: - response_format

    /// OpenRouter's `response-format-json-object` and `structured-output`
    /// shapes. GLM refused both with 400 before rendering; now the service's
    /// JSON instruction renders through the shipped template, the reasoning
    /// streams, and the answer is exposed once, validated and without the
    /// fences the model added.
    @Test(arguments: ["json_object", "json_schema"])
    func openRouterJSONRequestIsServedWithAValidatedAnswer(format: String) async throws {
        let body = format == "json_object" ? Self.jsonObjectBody() : Self.jsonSchemaBody()
        let prompts = PromptCapture()
        let served = try await serve(body, output: [
            "The user wants Austin's weather", " as one JSON object.</think>",
            "```json\n{\"city\": \"Austin\",", " \"temperature_f\": 75, \"conditions\": \"sunny\"}\n```",
        ], prompts: prompts)
        #expect(served.error == nil)
        #expect(served.reasoning == "The user wants Austin's weather as one JSON object.")
        let value = try #require(try JSONSerialization.jsonObject(with: Data(served.content.utf8)) as? [String: Any])
        #expect(value["city"] as? String == "Austin" && value["temperature_f"] as? Int == 75
            && value["conditions"] as? String == "sunny")
        // Reasoning streamed first; the answer left once, after validation.
        #expect(served.order.last == "content" && served.order.filter { $0 == "content" }.count == 1)
        #expect(served.finishReason == "stop")
        let prompt = try #require(prompts.prompts.first)
        #expect(prompt.contains("<|system|>You must respond with a single valid JSON"))
        #expect(prompt.hasSuffix("<|assistant|><think>"))
        if format == "json_schema" {
            #expect(prompt.contains("Schema name: weather_report."))
            #expect(prompt.contains(#""enum":["sunny","cloudy","rain","snow","windy"]"#))
        }
    }

    /// With thinking off the answer is the whole completion.
    @Test func thinkingOffJSONAnswerIsExposedOnce() async throws {
        var body = Self.jsonSchemaBody()
        body["reasoning"] = ["enabled": false]
        let prompts = PromptCapture()
        let served = try await serve(body, output: ["\n", Self.austin], prompts: prompts)
        #expect(served.error == nil && served.reasoning.isEmpty)
        #expect(served.content == Self.austin && served.order == ["content"])
        #expect(try #require(prompts.prompts.first).hasSuffix("<|assistant|><think>"))
        // The withheld answer still ends the pre-content interval when it is
        // generated, not when it validates (the relay's first-content deadline).
        #expect(served.firstWithheldOutputAt != nil)
    }

    /// Nothing unvalidated reaches the client: prose, a schema violation, a
    /// truncated value or an answer cut off in reasoning is a typed 422 after
    /// the streamed reasoning, with no content frame. Errors never quote output.
    @Test(arguments: [
        (["PRIVATE: it is sunny in Austin."], CBv2FinishReason.stop, "json_object"),
        (["[\"PRIVATE\"]"], .stop, "json_object"),
        ([#"{"city":"PRIVATE","temperature_f":75,"conditions":"hot"}"#], .stop, "json_schema"),
        ([#"{"city":"PRIVATE","temperature_f":75.5,"conditions":"sunny"}"#], .stop, "json_schema"),
        ([#"{"city":"PRIVATE","temperature_f":75,"conditions":"sunny","extra":1}"#], .stop, "json_schema"),
        ([#"{"city":"PRIVATE","temp"#], .length, "json_object"),
        (["PRIVATE reasoning that never ends"], .length, "json_schema"),
    ])
    func invalidJSONAnswerIsATyped422WithNoContent(
        output: [String], finish: CBv2FinishReason, format: String
    ) async throws {
        var body = format == "json_object" ? Self.jsonObjectBody() : Self.jsonSchemaBody()
        body["reasoning"] = ["enabled": false]
        let served = try await serve(body, output: output, finish: finish)
        #expect(served.content.isEmpty && served.finishReason == nil)
        let error = try #require(served.error as? MLXOpenAIServiceError)
        guard case .invalidResponseFormatOutput(let message) = error else {
            Issue.record("unexpected \(error)"); return
        }
        #expect(!message.contains("PRIVATE"))
        #expect(ProviderLoop.mapInferenceErrorToStatus(error) == 422)
    }

    /// Unsupported shapes stay explicit client errors before any generation.
    @Test func unsupportedJSONShapesAreRefusedBeforeGeneration() async throws {
        var withTools = Self.jsonObjectBody()
        withTools["tools"] = [["type": "function", "function": ["name": "ping",
            "parameters": ["type": "object", "properties": [String: Any]()]] as [String: Any]]]
        var untyped = Self.jsonSchemaBody()
        untyped["response_format"] = ["type": "json_schema", "json_schema": [
            "name": "loose", "schema": ["type": "object", "properties": ["value": [String: Any]()]]]]
        var pattern = Self.jsonSchemaBody()
        pattern["response_format"] = ["type": "json_schema", "json_schema": [
            "name": "pattern", "schema": ["type": "string", "pattern": "^a"]]]
        for body in [withTools, untyped, pattern] {
            let served = try await serve(body, output: [Self.austin])
            let error = try #require(served.error as? MultiModelBatchSchedulerEngineError)
            #expect(ProviderLoop.mapInferenceErrorToStatus(error) == 400)
            #expect(served.content.isEmpty)
        }
    }
}
