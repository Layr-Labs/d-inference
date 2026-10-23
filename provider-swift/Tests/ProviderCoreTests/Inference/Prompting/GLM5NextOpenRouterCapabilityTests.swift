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
    private let lock = NSLock()
    private var submitted: [CBv2Request] = []
    init(output: [String], finish: CBv2FinishReason = .stop) {
        self.output = output
        self.finish = finish
    }
    /// What GLM's native-tracked engine decides for each submission
    /// (`EngineV2Bridge.nativeOutputControlRefusal`); nil admits it.
    var nativeRefusals: [String?] {
        lock.withLock { submitted }.map {
            EngineV2Bridge.nativeOutputControlRefusal(nativeTracked: true,
                topLogprobs: $0.sampling.topLogprobs, constrained: $0.tokenConstraint != nil)
        }
    }
    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        lock.withLock { submitted.append(request) }
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
    /// The native engine's output-control decision for each submission.
    var nativeRefusals: [String?] = []
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
               prompts: PromptCapture = PromptCapture(),
               logprobs: EngineV2LogprobsPlumbing? = nil) async throws -> ServedResponse {
        let data = try JSONSerialization.data(withJSONObject: body)
        var request = try ProviderLoop.decodeOpenAIRequest(data, modelType: "glm5_next")
        request.reasoningParser = ProviderLoop.inferReasoningParser(for: "glm5_next")
        request.stream = true
        let controls = ProviderLoop.extractChatTemplateControls(from: data)
        let tokenizer = TokenizerHandle(try GLM5NextThinkingTokenizer(
            base: GLMTemplateTokenizer(template: try Self.shippedTemplate(), rendered: prompts)))
        let engine = ScriptedGLMEngine(output: output, finish: finish)
        let bridge = EngineV2Bridge(engine: engine,
            modelId: Self.model, tokenizer: tokenizer, eosTokenIds: [154820, 154827, 154829],
            kvBytesPerToken: 0)
        let usage = EngineV2RequestUsageSignal()
        let scheduler = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in
                [Self.model: .init(tokenizer: tokenizer, modelType: "glm5_next", engineV2Bridge: bridge)]
            },
            defaultMaxTokens: 2048, templateControls: controls, engineV2Logprobs: logprobs,
            engineV2Usage: usage)
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
        served.nativeRefusals = engine.nativeRefusals
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
        // No sampler constraint or logprobs: GLM's native engine admits it.
        #expect(served.nativeRefusals == [nil])
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
        #expect(served.nativeRefusals == [nil])
        #expect(try #require(prompts.prompts.first).hasSuffix("<|assistant|><think>"))
        // The withheld answer still ends the pre-content interval when it is
        // generated, not when it validates (the relay's first-content deadline).
        #expect(served.firstWithheldOutputAt != nil)
    }

    /// In a JSON request an earlier assistant turn keeps the reasoning
    /// OpenRouter returns as `reasoning` or `reasoning_details`, rendered
    /// exactly as `reasoning_content`, although the service inserted its
    /// instruction turn after the leading system turns.
    @Test(arguments: [false, true])
    func jsonModeMultiTurnRendersReturnedReasoning(leadingSystem: Bool) async throws {
        let thought = "Austin is sunny at 75F; answer with one object."
        func prompt(_ reasoning: [String: Any]) async throws -> String {
            var assistant: [String: Any] = ["role": "assistant", "content": Self.austin]
            assistant.merge(reasoning) { _, added in added }
            var messages: [[String: Any]] = [
                ["role": "user", "content": "Weather in Austin as JSON."], assistant,
                ["role": "user", "content": "Again, as one JSON object."],
            ]
            if leadingSystem { messages.insert(["role": "system", "content": "Be terse."], at: 0) }
            var body = Self.jsonObjectBody()
            body["messages"] = messages
            let prompts = PromptCapture()
            let served = try await serve(body, output: ["Done.</think>", Self.austin], prompts: prompts)
            #expect(served.error == nil && served.content == Self.austin)
            return try #require(prompts.prompts.first)
        }
        let expected = try await prompt(["reasoning_content": thought])
        #expect(expected.contains("<think>\(thought)</think>"))
        #expect(expected.contains("<|system|>You must respond with a single valid JSON object."))
        for returned: [String: Any] in [
            ["reasoning": thought],
            ["reasoning_details": [["type": "reasoning.summary", "summary": "Weather."],
                                   ["type": "reasoning.text", "text": thought]]],
        ] {
            #expect(try await prompt(returned) == expected)
        }
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

    // MARK: - Forced tool_choice

    /// OpenRouter's captured `orIncidentAuto` request, byte for byte as the
    /// platform conformance fixture holds it (`coordinator/tests/internal/
    /// conformance/incident_fixtures.go`): its `strict` weather tool with
    /// thinking off. The capability tests replace only `tool_choice`.
    static let capturedOpenRouterToolAuto = #"{"messages":[{"content":"What is the weather like in Boston, MA in fahrenheit?","role":"user"}],"reasoning":{"enabled":false},"stream":true,"tool_choice":"auto","tools":[{"function":{"description":"Get the current weather in a given location","name":"get_current_weather","parameters":{"additionalProperties":false,"properties":{"location":{"description":"The city and state, e.g. San Francisco, CA","type":"string"},"unit":{"enum":["celsius","fahrenheit"],"type":"string"}},"required":["location","unit"],"type":"object"},"strict":true},"type":"function"}]}"#
    static let weatherCall = "<tool_call>get_current_weather<arg_key>location</arg_key><arg_value>Boston, MA</arg_value><arg_key>unit</arg_key><arg_value>fahrenheit</arg_value></tool_call>"
    static var requiredChoice: Any { "required" }
    static var namedChoice: Any { ["type": "function", "function": ["name": "get_current_weather"]] }

    static func forcedToolBody(_ choice: Any, replacing fields: [String: Any] = [:]) throws -> [String: Any] {
        var body = try #require(JSONSerialization.jsonObject(
            with: Data(capturedOpenRouterToolAuto.utf8)) as? [String: Any])
        body["model"] = model
        body["tool_choice"] = choice
        body.merge(fields) { _, replacement in replacement }
        return body
    }

    /// OpenRouter's `tool-choice-required` and `tool-choice-function`. The
    /// coordinator refused both (no GLM provider advertised the tool-constraint
    /// protocol) and the provider refused them in its prompt policy. Now the
    /// forcing instruction renders, the call is withheld until it parses and
    /// validates, and it is exposed as one OpenAI tool call.
    @Test(arguments: ["required", "named"])
    func openRouterForcedToolChoiceIsServedWithAValidatedCall(choice: String) async throws {
        let body = try Self.forcedToolBody(choice == "required" ? Self.requiredChoice : Self.namedChoice)
        let prompts = PromptCapture()
        let served = try await serve(body, output: ["\n", Self.weatherCall], prompts: prompts)
        #expect(served.error == nil && served.content.isEmpty && served.reasoning.isEmpty)
        #expect(served.toolCalls.count == 1 && served.toolCalls.first?.name == "get_current_weather")
        let arguments = try #require(try JSONSerialization.jsonObject(
            with: Data((served.toolCalls.first?.arguments ?? "").utf8)) as? [String: String])
        #expect(arguments == ["location": "Boston, MA", "unit": "fahrenheit"])
        #expect(served.finishReason == "tool_calls")
        // No sampler constraint or logprobs: GLM's native engine admits it.
        #expect(served.nativeRefusals == [nil])
        let prompt = try #require(prompts.prompts.first)
        #expect(prompt.contains("<tools>\n{\"description\": \"Get the current weather in a given location\", \"name\": \"get_current_weather\""))
        #expect(prompt.contains(choice == "required"
            ? "Call the declared function 'get_current_weather' now." : "even when another function seems more relevant"))
        #expect(prompt.hasSuffix("fahrenheit?\n\nCall the declared function 'get_current_weather' now. You must emit one or more 'get_current_weather' tool calls with valid arguments before any final answer, "
            + (choice == "required" ? "even when the user's request does not require the tool. " : "even when another function seems more relevant. ")
            + "Include all independent calls to 'get_current_weather' requested by the user in this response. Do not stop after the first call or wait for results between independent calls. "
            + "Your entire response must consist of " + (choice == "required" ? "tool calls" : "'get_current_weather' tool calls")
            + "; a text answer is forbidden. For any required string argument without an obvious value, use the user's request text.<|assistant|><think>"))
        #expect(served.firstWithheldOutputAt != nil)
    }

    /// With thinking on, reasoning streams first and the withheld call follows.
    /// A named choice offers only the selected function.
    @Test func forcedCallAfterReasoningStreamsTheReasoningFirst() async throws {
        var body = try Self.forcedToolBody(Self.namedChoice, replacing: ["reasoning": ["enabled": true]])
        var tools = try #require(body["tools"] as? [[String: Any]])
        tools.append(["type": "function", "function": ["name": "get_forecast",
            "parameters": ["type": "object", "properties": ["city": ["type": "string"]]]] as [String: Any]])
        body["tools"] = tools
        let prompts = PromptCapture()
        let served = try await serve(body, output: [
            "Boston weather needs the tool", " in fahrenheit.</think>", Self.weatherCall,
        ], prompts: prompts)
        #expect(served.error == nil)
        #expect(served.reasoning == "Boston weather needs the tool in fahrenheit.")
        #expect(served.order.first == "reasoning" && served.order.last == "tool" && served.content.isEmpty)
        #expect(served.toolCalls.map(\.name) == ["get_current_weather"])
        #expect(served.nativeRefusals == [nil])
        let prompt = try #require(prompts.prompts.first)
        #expect(!prompt.contains("get_forecast"))
    }

    /// Control for the native-engine evidence above: the same check refuses a
    /// GLM logprobs row, which the native engine cannot serve.
    @Test func nativeEngineEvidenceRefusesALogprobsRow() async throws {
        var body = Self.jsonObjectBody()
        body.removeValue(forKey: "response_format")
        // The coordinator handler threads the sealed body's logprobs request
        // this way (`ProviderLoop+InferenceHandler`).
        let served = try await serve(body, output: ["Sunny."], logprobs: EngineV2LogprobsPlumbing(
            topLogprobs: 2, channel: EngineV2LogprobsChannel()))
        let refusal = try #require(served.nativeRefusals.first ?? nil)
        #expect(refusal.hasPrefix(EngineV2Translation.unsupportedOutputControlPrefix))
    }

    /// Prose, a missing call, the wrong function, a schema violation, a
    /// truncated frame or a call with trailing text is a typed 422 and nothing
    /// is exposed.
    @Test(arguments: [
        ("required", ["PRIVATE: it is 72F in Boston."], CBv2FinishReason.stop),
        ("required", ["PRIVATE " + weatherCall], .stop),
        ("required", [weatherCall.replacingOccurrences(of: "fahrenheit", with: "kelvin")], .stop),
        ("named", ["<tool_call>get_forecast<arg_key>city</arg_key><arg_value>PRIVATE</arg_value></tool_call>"], .stop),
        ("named", [String(weatherCall.prefix(60))], .length),
        ("named", [weatherCall + "PRIVATE trailing"], .stop),
    ])
    func noncompliantForcedOutputIsATyped422WithNothingExposed(
        choice: String, output: [String], finish: CBv2FinishReason
    ) async throws {
        let body = try Self.forcedToolBody(choice == "required" ? Self.requiredChoice : Self.namedChoice)
        let served = try await serve(body, output: output, finish: finish)
        #expect(served.toolCalls.isEmpty && served.content.isEmpty && served.finishReason == nil)
        let error = try #require(served.error as? MultiModelBatchSchedulerEngineError)
        guard case .toolChoiceViolation(let message) = error else {
            Issue.record("unexpected \(error)"); return
        }
        #expect(!message.contains("PRIVATE"))
        #expect(ProviderLoop.mapInferenceErrorToStatus(error) == 422)
    }

    /// The coordinator routes required/named GLM requests only to providers
    /// that list the concrete model under tool-constraint protocol v1.
    @Test func providerAdvertisesForcedToolChoiceForTheGLMServingIdentity() throws {
        func model(_ id: String, _ type: String?) -> ModelInfo {
            ModelInfo(id: id, modelType: type, sizeBytes: 1, estimatedMemoryGb: 1)
        }
        let models = [model(Self.model, "glm5_next"), model(GLM5NextLocalQualification.modelID, "glm5_next"),
                      model("glm-5.3-flash-unqualified", "glm5_next"), model(Self.model, "llama")]
        let bytes = try CoordinatorClientCodec.encodeOutboundMessage(.modelsUpdate(models: models))
        guard case .modelsUpdate(let update) = try ProviderProtocolCodec.decodeProviderMessage(from: bytes) else {
            Issue.record("expected models_update"); return
        }
        #expect(update.toolConstraintProtocol == 1)
        #expect(update.toolConstraintModels == [GLM5NextLocalQualification.modelID, Self.model].sorted())
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
