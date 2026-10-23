import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import Jinja
import MLXLMCommon
import NIOCore
import ProviderCoreFoundation
import Testing
@testable import ProviderCore

/// Live loopback HTTP through the Super hook's text route on the actual native
/// bridge with tiny synthetic weights. The scripted tokenizer renders the
/// pinned template (recording the prompt) and maps the N-th generated token to
/// the N-th script piece, so reasoning/tool/structured output is exact.
extension NemotronSuperLocalHTTPTests {
    @Test(.timeLimit(.minutes(2))) func liveHTTPTextReasoningToolsAndStructuredOutput() async throws {
        let (installed, construction, residency) = try SuperInstalledFixture().make()
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: .max) })
        let lease = try #require(await budget.claimPendingLoad(requestID: "super-text-http",
            weightBytes: UInt64(installed.receipt.payloadBytes), minimumKVBytes: 2 << 30))
        let script = SuperOutputScript()
        let tokenizer = TokenizerHandle(SuperScriptedTokenizer(script: script))
        let owner = try await NemotronSuperLocalBridgeBuilder.make(installed: installed,
            tokenizer: tokenizer, eosTokenIDs: [31],
            sizing: .init(weightsBytes: installed.receipt.payloadBytes, fp16KVBytesPerToken: 64,
                maxContextLength: 1024, defaultMaxTokens: 16), kvBytesCapacity: 2 << 30,
            kvBudget: budget, loadLease: lease, construction: construction, environment: [:])
        let template = try #require(Data(base64Encoded: superImagePinnedTemplateBase64,
                                        options: .ignoreUnknownCharacters))
        let hook = try NemotronSuperLocalImageHTTP(owner: owner, templateBytes: template)
        let token = "synthetic-super-text"
        let app = makeLocalInferenceApplication(
            config: .init(host: "127.0.0.1", port: 0, authToken: token), defaultMaxTokens: 16,
            acquire: { id in throw MultiModelBatchSchedulerEngineError.modelNotLoaded(id) },
            tokenizerProvider: { _ in .init(tokenizer: tokenizer, modelType: "nemotron_h_omni") },
            availableModels: { [] }, mtpSlots: { [] },
            modelTypeProvider: { _ in "nemotron_h_omni" }, nemotronSuperImageHTTP: hook)
        let headers: HTTPFields = [.contentType: "application/json", .authorization: "Bearer " + token]
        @Sendable func weather() -> [String: Any] {
            ["type": "function", "function": ["name": "get_weather",
                "parameters": ["type": "object", "properties": ["city": ["type": "string"]],
                               "required": ["city"]]]]
        }
        @Sendable func body(_ pieces: [String], stream: Bool, _ extra: [String: Any] = [:]) throws -> ByteBuffer {
            script.set(pieces)
            var value: [String: Any] = ["model": NemotronSuperLocalBinding.modelID, "stream": stream,
                "temperature": 0, "max_tokens": pieces.count,
                "messages": [["role": "system", "content": "Be brief."], ["role": "user", "content": "Hi"]]]
            value.merge(extra) { _, new in new }
            return ByteBuffer(bytes: try JSONSerialization.data(withJSONObject: value))
        }
        let baseline = await budget.outstandingReservedBytes()
        try await app.test(.live) { client in
            func send(_ buffer: ByteBuffer, status: HTTPResponse.Status = .ok) async throws -> String {
                try await client.execute(uri: "/v1/chat/completions", method: .post,
                    headers: headers, body: buffer) { response in
                    #expect(response.status == status)
                    return String(buffer: response.body)
                }
            }
            let reasoning = ["Plan", " it.", "</think>", "Hello", " there."]
            let streamed = SuperSSE(try await send(body(reasoning, stream: true)))
            #expect(streamed.reasoning == "Plan it.")
            #expect(streamed.content == "Hello there.")
            #expect(streamed.finishReason == "length")
            #expect(script.prompt.hasSuffix("<|im_start|>assistant\n<think>\n"))
            #expect(script.prompt.hasPrefix("<|im_start|>system\nBe brief.<|im_end|>\n"))
            let complete = try SuperJSON(try await send(body(reasoning, stream: false)))
            #expect(complete.reasoning == "Plan it.")
            #expect(complete.content == "Hello there.")

            let off = SuperSSE(try await send(body(["<think>", "x", "</think>", "y"], stream: true,
                ["chat_template_kwargs": ["enable_thinking": false]])))
            #expect(off.reasoning == "")
            #expect(off.content == "<think>x</think>y")
            #expect(script.prompt.hasSuffix("<|im_start|>assistant\n<think></think>"))

            let call = ["Use tool.", "</think>", "<tool_call>", "\n<function=get_weather>",
                        "\n<parameter=city>", "\nParis", "\n</parameter>", "\n</function>", "\n</tool_call>"]
            for stream in [true, false] {
                let text = try await send(body(call, stream: stream, ["tools": [weather()]]))
                #expect(script.prompt.contains("<name>get_weather</name>"))
                let calls = stream ? SuperSSE(text).toolCalls : try SuperJSON(text).toolCalls
                #expect(calls.map(\.name) == ["get_weather"])
                #expect(calls.map(\.arguments) == [#"{"city":"Paris"}"#])
                #expect(text.contains(#""finish_reason":"tool_calls""#))
                #expect(!text.contains("<tool_call>"))
            }
            let structured = try SuperJSON(try await send(body(["{\"ok\"", ": true}"], stream: false,
                ["enable_thinking": false, "response_format": ["type": "json_object"]])))
            #expect(structured.content == #"{"ok": true}"#)
            #expect(script.prompt.contains("You must respond with a single valid JSON object."))
            let streamedJSON = SuperSSE(try await send(body(["think", "</think>", "{\"n\":", " 1}"], stream: true,
                ["response_format": ["type": "json_object"]])))
            #expect(streamedJSON.reasoning == "think")
            #expect(streamedJSON.content == #"{"n": 1}"#)

            _ = try await send(body(["not", " json"], stream: false,
                ["enable_thinking": false, "response_format": ["type": "json_object"]]), status: .unprocessableContent)
            // Streamed, the held answer's first chunk sent the headers: its
            // failed validation is a stream error, and no held text leaks.
            let failedJSON = try await send(body(["not", " json"], stream: true,
                ["enable_thinking": false, "response_format": ["type": "json_object"]]))
            #expect(failedJSON.contains(#""finish_reason":"error""#) && !failedJSON.contains("[DONE]"))
            #expect(SuperSSE(failedJSON).content.isEmpty)
            _ = try await send(body(["</think>", "Sure."], stream: false,
                ["tools": [weather()], "tool_choice": "required"]), status: .unprocessableContent)
            // A JSON format with tools: a call is returned as a call, an answer must be JSON.
            for stream in [true, false] {
                let jsonTools: [String: Any] = ["tools": [weather()], "response_format": ["type": "json_object"]]
                let called = try await send(body(call, stream: stream, jsonTools))
                let calls = stream ? SuperSSE(called).toolCalls : try SuperJSON(called).toolCalls
                #expect(calls.map(\.name) == ["get_weather"])
                #expect(script.prompt.contains("<name>get_weather</name>")
                    && script.prompt.contains("You must respond with a single valid JSON object."))
                let answered = try await send(body(["Use tool?", "</think>", "{\"city\"", ": \"Paris\"}"],
                                                   stream: stream, jsonTools))
                let content = stream ? SuperSSE(answered).content : try SuperJSON(answered).content
                #expect(content == #"{"city": "Paris"}"#)
            }
            _ = try await send(body(["</think>", "Sunny."], stream: false,
                ["tools": [weather()], "response_format": ["type": "json_object"]]), status: .unprocessableContent)
            for invalid in [["enable_thinking": false, "chat_template_kwargs": ["enable_thinking": true]],
                            ["logprobs": true],
                            ["messages": [["role": "user", "content": "a <image> tag"]]]] as [[String: Any]] {
                let text = try await send(body(["x"], stream: true, invalid), status: .badRequest)
                #expect(text.contains("error"))
            }
        }
        #expect(await budget.outstandingReservedBytes() == baseline)
        await hook.drain()
        try await owner.closeAfterDrain()
        try await app.test(.live) { client in
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: headers,
                body: try body(["x"], stream: false)) { response in
                #expect(response.status == .serviceUnavailable)
            }
        }
        #expect(residency.snapshot.usedBytes == 0)
        #expect(await budget.finishPendingLoad(lease))
        #expect(await budget.outstandingReservedBytes() == 0)
    }
}

/// Script and last rendered prompt, shared with the tokenizer across tasks.
final class SuperOutputScript: @unchecked Sendable {
    private let lock = NSLock()
    private var pieces: [String] = []
    private var rendered = ""
    func set(_ value: [String]) { lock.withLock { pieces = value } }
    var prompt: String { lock.withLock { rendered } }
    func record(_ prompt: String) { lock.withLock { rendered = prompt } }
    func decode(count: Int) -> String { lock.withLock { pieces.prefix(count).joined() } }
}

/// Generated token N decodes to script piece N (pieces never end in a newline,
/// which would restart the streaming detokenizer's segment).
struct SuperScriptedTokenizer: MLXLMCommon.Tokenizer {
    let script: SuperOutputScript
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [1, 2, 3] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { script.decode(count: tokenIds.count) }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        throw MLXLMCommon.TokenizerError.missingChatTemplate
    }
    func applyChatTemplate(messages: [[String: any Sendable]], chatTemplate: String,
                           tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] {
        let template = try Template(normalizeSwiftJinjaTemplate(chatTemplate),
                                    with: .init(lstripBlocks: true, trimBlocks: true))
        var context: [String: Value] = ["messages": .array(try messages.map { try Value(any: $0) }),
                                        "add_generation_prompt": true]
        for (key, value) in additionalContext ?? [:] { context[key] = try Value(any: value) }
        let prompt = try template.render(context)
        script.record(prompt)
        // A literal `<image>` must still reach the plan's media refusal.
        return prompt.contains("<image>") ? [1, 18, 2] : [1, 2, 3]
    }
}

struct SuperSSE {
    var reasoning = "", content = "", finishReason: String?
    var toolCalls: [(name: String, arguments: String)] = []
    init(_ body: String) {
        for line in body.split(separator: "\n") where line.hasPrefix("data: {") {
            guard let data = line.dropFirst(6).data(using: .utf8),
                let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let choice = (frame["choices"] as? [[String: Any]])?.first else { continue }
            if let reason = choice["finish_reason"] as? String { finishReason = reason }
            guard let delta = choice["delta"] as? [String: Any] else { continue }
            reasoning += delta["reasoning_content"] as? String ?? ""
            content += delta["content"] as? String ?? ""
            for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                let function = call["function"] as? [String: Any] ?? [:]
                toolCalls.append((function["name"] as? String ?? "", function["arguments"] as? String ?? ""))
            }
        }
    }
}

struct SuperJSON {
    let reasoning: String?, content: String?
    let toolCalls: [(name: String, arguments: String)]
    init(_ body: String) throws {
        let root = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        let message = try #require(((root["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any])
        reasoning = message["reasoning_content"] as? String
        content = message["content"] as? String
        toolCalls = (message["tool_calls"] as? [[String: Any]] ?? []).map { call in
            let function = call["function"] as? [String: Any] ?? [:]
            return (function["name"] as? String ?? "", function["arguments"] as? String ?? "")
        }
    }
}
