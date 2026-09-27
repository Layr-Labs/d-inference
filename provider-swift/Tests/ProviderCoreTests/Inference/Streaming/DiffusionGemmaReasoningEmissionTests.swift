import Foundation
import Hummingbird
import HummingbirdTesting
import MLXLMCommon
import MLXLMServer
import NIOCore
import Testing

@testable import ProviderCore

/// Replays a captured malformed native boundary through the actual provider
/// adapter. Scripted engine output is not a model-quality or GPU assertion.
@Suite("DiffusionGemma reasoning output policy", .serialized)
struct DiffusionGemmaReasoningEmissionTests {
    private let call = #"<|tool_call>call:get_weather{city:<|"|>Paris<|"|>}<tool_call|>"#

    @Test func disabledReasoningFailureNeverExposesThoughtOrInvokesItsTool() async throws {
        for responses in [false, true] {
            for width in [1, 7, 512] {
                let result = try await collect(output: "<|channel>thought\n" + call,
                    responses: responses, reasoning: false, width: width)
                #expect(result.failed, "Malformed thought must not become a successful forced call")
                #expect(result.reasoning.isEmpty, "Disabled reasoning must not escape before the failure")
                #expect(result.content.isEmpty && result.calls.isEmpty)
            }
        }
    }

    @Test func enabledReasoningAndProperlyClosedToolsRemainSeparate() async throws {
        let result = try await collect(output: "<|channel>thought\nCheck the requested city.<channel|>" + call,
            responses: true, reasoning: true, width: 7)
        #expect(!result.failed && result.reasoning == "Check the requested city.")
        #expect(result.content.isEmpty && result.calls.count == 1)
        #expect(result.calls.first?.function.name == "get_weather")
        #expect(result.calls.first?.function.arguments["city"] == .string("Paris"))
    }

    @Test func disabledEmptyEnvelopesStillAllowTheValidCall() async throws {
        for prefix in ["<|channel>thought<channel|>", "<|channel>thought\n<channel|>",
            "<|channel>thought\n \t\n<channel|>"] {
            let result = try await collect(output: prefix + call, responses: true, reasoning: false, width: 1)
            #expect(!result.failed && result.reasoning.isEmpty && result.content.isEmpty)
            #expect(result.calls.count == 1 && result.calls.first?.function.name == "get_weather")
        }
    }

    @Test func disabledViolationCannotResumeAndLiteralArgumentMarkersStayData() throws {
        for width in [1, 7, 512] {
            let handler = BatchedToolStreamHandler(format: .gemma, tools: nil, strictGemma: true)
            var router = NativeToolStreamRouter(handler: handler, requiresToolCall: true,
                nativePrefix: nil, nativeGemmaChannels: true, nativeGemmaReasoningEnabled: false)
            let characters = Array("<|channel>thought\nprivate example: " + call)
            var events = [MLXServerGenerationEvent](), rejected = false
            do {
                for start in stride(from: 0, to: characters.count, by: width) {
                    events += try router.process(String(characters[start..<min(start + width, characters.count)]))
                }
                events += try router.finishText()
            } catch { rejected = true }
            #expect(rejected && events.isEmpty && handler.finish().isEmpty)
            #expect(throws: (any Error).self) { try router.process("<channel|>" + call) }
            #expect(throws: (any Error).self) { try router.finishText() }
        }
        let value = "literal <|channel>thought example<channel|>"
        let handler = BatchedToolStreamHandler(format: .gemma, tools: nil, strictGemma: true)
        var router = NativeToolStreamRouter(handler: handler, requiresToolCall: true,
            nativePrefix: nil, nativeGemmaChannels: true, nativeGemmaReasoningEnabled: false)
        let frame = "<|tool_call>call:echo{text:<|\"|>" + value + "<|\"|>}<tool_call|>"
        for character in frame { #expect(try router.process(String(character)).isEmpty) }
        #expect(try router.finishText().isEmpty)
        #expect(handler.finish().first?.function.arguments["text"] == .string(value))
    }

    @Test func actualLocalHTTPKeepsAuthAndNeverSerializesDisabledThoughtOnFailure() async throws {
        for responses in [false, true] {
            for streaming in [false, true] {
                let id = "native-diffusion-emission-http"
                let tokenizer = TokenizerHandle(EmissionTokenizer())
                let native = EmissionEngine(text: "<|channel>thought\n" + call, width: 1)
                let bridge = EngineV2Bridge(engine: native, modelId: id, tokenizer: tokenizer, eosTokenIds: [])
                let token = UUID().uuidString
                let app = makeLocalInferenceApplication(config: .init(port: 0, authToken: token),
                    defaultMaxTokens: 256,
                    acquire: { _ in .init(tokenizer: tokenizer,
                        releaseToken: .init(release: { _ in }, modelId: id),
                        modelType: "diffusion_gemma", engineV2Bridge: bridge) },
                    tokenizerProvider: { _ in .init(tokenizer: tokenizer, modelType: "diffusion_gemma") },
                    availableModels: { [id] }, mtpSlots: { [] })
                let body = ByteBuffer(data: try requestData(id: id, responses: responses, reasoning: false, stream: streaming))
                let route = responses ? "/v1/responses" : "/v1/chat/completions"
                do {
                    try await app.test(.ahc()) { client in
                        try #require(client.port != nil)
                        let unauthorized = try await client.execute(uri: route, method: .post,
                            headers: [.contentType: "application/json"], body: body)
                        #expect(unauthorized.status == .unauthorized && native.submissionCount == 0)
                        let response = try await client.execute(uri: route, method: .post,
                            headers: [.contentType: "application/json", .authorization: "Bearer \(token)"], body: body)
                        let text = String(buffer: response.body)
                        #expect(native.submissionCount == 1)
                        #expect(!text.contains("Paris") && !text.contains("get_weather") && !text.contains("<|channel>"))
                        #expect(!text.contains("reasoning_summary_text.delta") && !text.contains("reasoning_content"))
                        if streaming {
                            #expect(response.status == .ok)
                            let frames = try text.components(separatedBy: "\n").filter {
                                $0.hasPrefix("data: ") && $0 != "data: [DONE]"
                            }.map { try #require(JSONSerialization.jsonObject(with: Data($0.dropFirst(6).utf8)) as? [String: Any]) }
                            let last = try #require(frames.last)
                            if responses {
                                #expect(last["type"] as? String == "response.failed")
                            } else {
                                #expect(last["error"] is [String: Any])
                                let choices = try #require(last["choices"] as? [[String: Any]])
                                #expect(choices.first?["finish_reason"] as? String == "error")
                            }
                        } else {
                            #expect(response.status.code == 422)
                            let payload = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                            #expect(payload["error"] is [String: Any])
                        }
                    }
                } catch {
                    await bridge.shutdown()
                    throw error
                }
                await bridge.shutdown()
            }
        }
    }

    private func collect(output: String, responses: Bool, reasoning: Bool, width: Int) async throws
        -> (failed: Bool, reasoning: String, content: String, calls: [ToolCall])
    {
        let id = "native-diffusion-emission-fixture"
        let tokenizer = TokenizerHandle(EmissionTokenizer())
        let bridge = EngineV2Bridge(engine: EmissionEngine(text: output, width: width),
            modelId: id, tokenizer: tokenizer, eosTokenIds: [])
        let entry = MultiModelBatchSchedulerEngine.ModelRegistryEntry(tokenizer: tokenizer,
            modelType: "diffusion_gemma", engineV2Bridge: bridge)
        let engine = MultiModelBatchSchedulerEngine(registryProvider: { [id: entry] })
        let data = try requestData(id: id, responses: responses, reasoning: reasoning)
        let request = try responses
            ? JSONDecoder().decode(OpenAIResponseRequest.self, from: data).chatCompletionRequest
            : JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: data)
        var failed = false, thought = "", content = "", calls = [ToolCall]()
        do {
            for try await event in try await engine.streamChatCompletion(request: request) {
                switch event {
                case .parsed(let piece):
                    thought += piece.reasoningContent ?? ""
                    content += piece.content
                case .content(let text): content += text
                case .toolCall(let call): calls.append(call)
                default: break
                }
            }
        } catch {
            failed = true
            #expect(ProviderLoop.mapInferenceErrorToStatus(error) == 422)
            #expect(ProviderLoop.sanitizedInferenceFailure(from: error, phase: .generation).errorReason == .toolNoncompliance)
        }
        await bridge.shutdown()
        return (failed, thought, content, calls)
    }

    private func requestData(id: String, responses: Bool, reasoning: Bool, stream: Bool = true) throws -> Data {
        let function: [String: Any] = ["name": "get_weather", "parameters": ["type": "object",
            "properties": ["city": ["type": "string"]], "required": ["city"], "additionalProperties": false]]
        var body: [String: Any] = ["model": id, "stream": stream, "parallel_tool_calls": false]
        if responses {
            var tool = function
            tool["type"] = "function"
            body.merge(["input": "Use the declared weather tool for Paris.", "tools": [tool],
                "tool_choice": ["type": "function", "name": "get_weather"],
                "reasoning": ["effort": reasoning ? "medium" : "none"], "max_output_tokens": 256]) { _, new in new }
        } else {
            body.merge(["messages": [["role": "user", "content": "Use the declared weather tool for Paris."]],
                "tools": [["type": "function", "function": function]],
                "tool_choice": ["type": "function", "function": ["name": "get_weather"]],
                "reasoning": ["enabled": reasoning], "max_tokens": 256]) { _, new in new }
        }
        return try JSONSerialization.data(withJSONObject: body)
    }
}

private final class EmissionEngine: CBv2Engine, @unchecked Sendable {
    let chunks: [String]
    private let lock = NSLock()
    private var submissions = 0
    var submissionCount: Int { lock.withLock { submissions } }
    init(text: String, width: Int) {
        let characters = Array(text)
        chunks = stride(from: 0, to: characters.count, by: width).map {
            String(characters[$0..<min($0 + width, characters.count)])
        }
    }
    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        lock.withLock { submissions += 1 }
        return AsyncStream { continuation in
            for chunk in chunks { continuation.yield(.delta(text: chunk, tokens: [9], logprobs: nil)) }
            continuation.yield(.finished(reason: .stop,
                usage: .init(promptTokens: request.promptTokens.count, completionTokens: chunks.count)))
            continuation.finish()
        }
    }
    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        .init(activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0, kvBytesCapacity: 0, activeTokens: 0)
    }
    func shutdown() async {}
}

private struct EmissionTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [1, 2, 3] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "prompt" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?) throws -> [Int] { [1, 2, 3] }
}
