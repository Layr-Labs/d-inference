import Foundation
import Hummingbird
import HummingbirdTesting
import MLX
import NIOCore
import ProviderCoreFoundation
import Testing

@testable import ProviderCore

private final class DiffusionStandaloneBundleAnchor: NSObject {}

/// Real lazy slot loading and authenticated HTTP serialization in the router
/// harness. No socket/hosted/attestation claim and no persistent credentials.
@Suite("DiffusionGemma standalone HTTP qualification", .serialized)
struct DiffusionGemmaStandaloneLiveTests {
    private final class Receipts: @unchecked Sendable {
        private let lock = NSLock()
        private var payloads = [Data]()
        func append(_ value: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            lock.withLock { payloads.append(data) }
        }
        func values() throws -> [Any] {
            try lock.withLock { try payloads.map { try JSONSerialization.jsonObject(with: $0) } }
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_DIFFUSION_HTTP_LIVE"] == "1"))
    func coldChatStreamingAndResponsesUseNativeSlot() async throws {
        let modelID = "mlx-community/diffusiongemma-26B-A4B-it-4bit"
        let selected = URL(fileURLWithPath: try #require(
            ProcessInfo.processInfo.environment["DARKBLOOM_DIFFUSION_MODEL_DIR"]))
        let resolved = try #require(ModelScanner.resolveLocalPath(modelID: modelID))
        try #require(resolved.appendingPathComponent("config.json").resolvingSymlinksInPath().standardizedFileURL
            == selected.appendingPathComponent("config.json").standardizedFileURL)
        // Do not let a live fixture delete an operator's retired cache tree.
        try #require(!FileManager.default.fileExists(atPath: LegacyKVCacheSweeper.defaultKVRoot().path))
        _ = Bundle(for: DiffusionStandaloneBundleAnchor.self).bundleURL
        let model = try #require(ModelScanner.parseModelInfo(snapshotDir: resolved, modelName: modelID))
        try #require(model.modelType == "diffusion_gemma" && model.templateRenderOK != false)
        let token = UUID().uuidString + UUID().uuidString
        let server = StandaloneServer(config: .init(authToken: token,
            coordinatorURL: "http://127.0.0.1:1"), models: [model])
        // Router testing does not invoke start() or bind a socket. Mirror its
        // running state so normal stop() actually drains the loaded slot.
        await server.activateDiffusionRouterHarness()
        let app = server.makeApplication()
        let prompt = "Explain why leaves are green in three clear sentences."
        let chat: [String: Any] = ["model": modelID,
            "messages": [["role": "user", "content": prompt]],
            "temperature": 1, "max_tokens": 256, "seed": 4100,
            "reasoning": ["enabled": false], "stream": false]
        let data = try JSONSerialization.data(withJSONObject: chat)
        var streaming = chat
        streaming["stream"] = true
        streaming["stream_options"] = ["include_usage": true]
        let streamingData = try JSONSerialization.data(withJSONObject: streaming)
        let responses: [String: Any] = ["model": modelID, "input": prompt,
            "max_output_tokens": 256, "temperature": 1, "reasoning": ["effort": "none"]]
        let responsesData = try JSONSerialization.data(withJSONObject: responses)
        let results = Receipts()
        do {
            try await app.test(.router) { client in
                try await client.execute(uri: "/v1/chat/completions", method: .post,
                    headers: [.contentType: "application/json"], body: ByteBuffer(data: data)) { response in
                    #expect(response.status == .unauthorized)
                }
                try await client.execute(uri: "/v1/chat/completions", method: .post,
                    headers: [.contentType: "application/json", .authorization: "Bearer \(token)"],
                    body: ByteBuffer(data: data)) { response in
                    let body = Data(response.body.readableBytesView)
                    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
                    try #require(response.status == .ok, "Cold native HTTP chat must succeed: \(json)")
                    let choices = try #require(json["choices"] as? [[String: Any]])
                    let message = try #require(choices.first?["message"] as? [String: Any])
                    let content = try #require(message["content"] as? String)
                    #expect(content.lowercased().contains("chlorophyll"))
                    #expect(!content.contains("<|channel>") && !content.contains("<channel|>"))
                    #expect((message["reasoning_content"] as? String ?? "").isEmpty)
                    #expect(choices.first?["finish_reason"] as? String == "stop")
                    try results.append(["route": "chat", "status": response.status.code, "content": content,
                                    "usage": json["usage"] ?? [:]])
                }
                try await client.execute(uri: "/v1/chat/completions", method: .post,
                    headers: [.contentType: "application/json", .authorization: "Bearer \(token)"],
                    body: ByteBuffer(data: streamingData)) { response in
                    let body = String(buffer: response.body)
                    try #require(response.status == .ok)
                    #expect(body.contains("[DONE]"))
                    #expect(!body.contains("<|channel>") && !body.contains("<channel|>"))
                    try results.append(["route": "chat-stream", "status": response.status.code,
                                    "done": body.contains("[DONE]")])
                }
                try await client.execute(uri: "/v1/responses", method: .post,
                    headers: [.contentType: "application/json", .authorization: "Bearer \(token)"],
                    body: ByteBuffer(data: responsesData)) { response in
                    let body = String(buffer: response.body)
                    try #require(response.status == .ok, "Native Responses request failed: \(body)")
                    #expect(!body.contains("<|channel>") && !body.contains("<channel|>"))
                    #expect(body.lowercased().contains("chlorophyll"))
                    try results.append(["route": "responses", "status": response.status.code])
                }
            }
        } catch {
            await server.stopAndWait()
            throw error
        }
        await server.stopAndWait()
        #expect(await server.debugActiveRequestCount(modelId: modelID) == nil)
        let report: [String: Any] = ["scope": "authenticated router + real standalone lazy load",
            "results": try results.values(), "fullSupportQualification": false, "hostedQualification": false]
        print("DIFFUSION_HTTP " + String(decoding: try JSONSerialization.data(
            withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_DIFFUSION_TOOLS_LIVE"] == "1"))
    func reasoningAndAutomaticToolsAcrossHTTP() async throws {
        let modelID = "mlx-community/diffusiongemma-26B-A4B-it-4bit"
        let directory = try #require(ModelScanner.resolveLocalPath(modelID: modelID))
        try #require(!FileManager.default.fileExists(atPath: LegacyKVCacheSweeper.defaultKVRoot().path))
        _ = Bundle(for: DiffusionStandaloneBundleAnchor.self).bundleURL
        let model = try #require(ModelScanner.parseModelInfo(snapshotDir: directory, modelName: modelID))
        let token = UUID().uuidString + UUID().uuidString
        let server = StandaloneServer(config: .init(authToken: token, coordinatorURL: "http://127.0.0.1:1"), models: [model])
        await server.activateDiffusionRouterHarness()
        let app = server.makeApplication()
        struct Case: Sendable { let name: String; let data: Data; let kind: String; let reasoning: Bool }
        let literal = "A \"quote\"; path C:\\tmp\\file; café 🌊; literal <|channel>thought example<channel|>."
        let tool: [String: Any] = ["type": "function", "function": [
            "name": "get_weather", "description": "Get the current weather for a city.",
            "parameters": ["type": "object", "properties": ["city": ["type": "string"]],
                           "required": ["city"], "additionalProperties": false]]]
        var cases = [Case]()
        for reasoning in [false, true] {
            for kind in ["plain", "auto", "none", "required", "named", "parallel", "history", "literal"] {
                let prompt: String
                switch kind {
                case "plain": prompt = "What is 17 times 19? Briefly work it out and state the result."
                case "none": prompt = "Tool use is disabled. Do not call a tool. Reply simply: Tool use is disabled."
                case "parallel": prompt = "Call get_weather for Paris, Tokyo, Berlin, and London. Make all four independent calls now; do not wait for results between calls."
                case "history": prompt = "In one sentence, report the temperature and condition from the tool result."
                case "literal": prompt = "Use record_text to store this exact text, preserving every character: " + literal
                default: prompt = "Use get_weather to check the current weather in Paris. Do not guess the weather."
                }
                var request: [String: Any] = ["model": modelID, "messages": [["role": "user", "content": prompt]],
                    "reasoning": ["enabled": reasoning], "temperature": 1, "max_tokens": 512,
                    "seed": 7419, "stream": false]
                if kind != "plain" {
                    request["tools"] = [tool]
                    request["tool_choice"] = kind == "named"
                        ? ["type": "function", "function": ["name": "get_weather"]]
                        : (kind == "parallel" || kind == "literal" ? "required" : kind == "history" ? "auto" : kind)
                }
                if kind == "parallel" { request["parallel_tool_calls"] = true }
                if kind == "history" {
                    request["messages"] = [
                        ["role": "user", "content": "Check the weather in Paris."],
                        ["role": "assistant", "tool_calls": [["id": "weather-result-1", "type": "function",
                            "function": ["name": "get_weather", "arguments": "{\"city\":\"Paris\"}"]]]],
                        ["role": "tool", "tool_call_id": "weather-result-1", "name": "get_weather",
                            "content": "{\"city\":\"Paris\",\"temperature_c\":20,\"condition\":\"sunny\"}"],
                        ["role": "user", "content": prompt],
                    ]
                }
                if kind == "literal" {
                    request["tools"] = [["type": "function", "function": [
                        "name": "record_text", "description": "Store the provided text unchanged.",
                        "parameters": ["type": "object", "properties": ["text": ["type": "string"]],
                            "required": ["text"], "additionalProperties": false]]]]
                }
                cases.append(Case(name: "\(kind)-thinking-\(reasoning)",
                    data: try JSONSerialization.data(withJSONObject: request), kind: kind, reasoning: reasoning))
            }
        }
        let fixtures = cases
        let receipts = Receipts()
        do {
            try await app.test(.router) { client in
                for item in fixtures {
                    try await client.execute(uri: "/v1/chat/completions", method: .post,
                        headers: [.contentType: "application/json", .authorization: "Bearer \(token)"],
                        body: ByteBuffer(data: item.data)) { response in
                        let json = try #require(try JSONSerialization.jsonObject(
                            with: Data(response.body.readableBytesView)) as? [String: Any])
                        try receipts.append(["case": item.name, "status": response.status.code, "response": json])
                        #expect(response.status == .ok, "\(item.name): \(json)")
                        guard response.status == .ok else { return }
                        let choices = try #require(json["choices"] as? [[String: Any]])
                        let message = try #require(choices.first?["message"] as? [String: Any])
                        let content = message["content"] as? String ?? ""
                        let thought = message["reasoning_content"] as? String ?? ""
                        #expect(!content.contains("<|channel>") && !content.contains("<channel|>"))
                        #expect(!content.contains("<|tool_call>") && !content.contains("<tool_call|>"))
                        if !item.reasoning { #expect(thought.isEmpty, "Thinking OFF must not expose a reasoning channel") }
                        if ["auto", "required", "named", "parallel", "literal"].contains(item.kind) {
                            let calls = message["tool_calls"] as? [[String: Any]] ?? []
                            #expect(calls.count == (item.kind == "parallel" ? 4 : 1), "\(item.name) call count")
                            if let function = calls.first?["function"] as? [String: Any] {
                                #expect(function["name"] as? String == (item.kind == "literal" ? "record_text" : "get_weather"))
                                let arguments = try #require(function["arguments"] as? String)
                                let object = try #require(try JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any])
                                if item.kind == "literal" { #expect(object["text"] as? String == literal) }
                                else if item.kind != "parallel" { #expect(object["city"] as? String == "Paris") }
                            }
                            if item.kind == "parallel" {
                                let cities = try calls.map { call -> String in
                                    let function = try #require(call["function"] as? [String: Any])
                                    #expect(function["name"] as? String == "get_weather")
                                    let arguments = try #require(function["arguments"] as? String)
                                    let object = try #require(try JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any])
                                    return try #require(object["city"] as? String)
                                }
                                #expect(Set(cities) == Set(["Paris", "Tokyo", "Berlin", "London"]))
                            }
                            #expect(choices.first?["finish_reason"] as? String == "tool_calls")
                        } else {
                            #expect((message["tool_calls"] as? [[String: Any]] ?? []).isEmpty)
                            if item.kind == "history" {
                                #expect(content.contains("20") && content.lowercased().contains("sunny"))
                            } else { #expect(content.lowercased().contains(item.kind == "plain" ? "323" : "disabled")) }
                            #expect(choices.first?["finish_reason"] as? String == "stop")
                        }
                    }
                }
            }
        } catch {
            await server.stopAndWait()
            throw error
        }
        await server.stopAndWait()
        for result in try receipts.values() {
            print("DIFFUSION_TOOL_HTTP " + String(decoding: try JSONSerialization.data(
                withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
        }
        #expect(await server.debugActiveRequestCount(modelId: modelID) == nil)
    }
}

extension StandaloneServer {
    func activateDiffusionRouterHarness() { lifecycleState = .running }
}
