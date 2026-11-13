// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMServer
import ProviderCoreFoundation
import Testing
@testable import ProviderCore

/// Opt-in real weights, production slot and loopback HTTP. The token is
/// ephemeral, the model root is explicit, and no coordinator is contacted.
/// Nothing here starts a service or takes this Mac's serving lock.
///
///   DARKBLOOM_MUSE_GLIMMER_LIVE=1
///   DARKBLOOM_MUSE_GLIMMER_HUB=<Hugging Face hub root holding the pinned snapshot>
///   DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL=1
///   DARKBLOOM_PREFIX_CACHE_TEST_ROOT=<empty directory for this run's prefix cache>
///   DARKBLOOM_MUSE_GLIMMER_RECEIPTS=<file>   (optional: one JSON line per request)
///
/// The prefix cache must be the isolated test root, which the store encrypts
/// under a key held in memory: the run never opens the operator's cache
/// directory or its persistent key.
///
/// It proves that the provider loads the pinned checkpoint into a paged slot
/// and that a client receives reasoning, answer and tool calls in their own
/// fields. It is not a quality, speed or memory qualification.
@Suite("Muse Glimmer physical-machine HTTP", .serialized)
struct MuseGlimmerLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_MUSE_GLIMMER_LIVE"] == "1"))
    func chatReasoningToolsAndPrefixReuse() async throws {
        let env = ProcessInfo.processInfo.environment
        let root = try #require(env["DARKBLOOM_MUSE_GLIMMER_HUB"])
        let previous = ModelScanner.configuredCacheDirectory
        ModelScanner.configureCacheDirectory(root)
        defer { ModelScanner.configureCacheDirectory(previous) }
        try #require(SSDPrefixCacheFactory.isolatedTestRoot(environment: env) != nil,
            "set DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL=1 and DARKBLOOM_PREFIX_CACHE_TEST_ROOT")
        try #require(SSDPrefixCacheFactory.forceEphemeralKey(environment: env),
            "this run must not load a persistent cache key")

        let id = MuseGlimmerModelPolicy.localModelID
        let directory = try #require(ModelScanner.resolveLocalPath(modelID: id))
        let model = try #require(ModelScanner.parseModelInfo(snapshotDir: directory, modelName: id))
        try #require(model.modelType == MuseGlimmerModelPolicy.modelType && model.templateRenderOK == true)
        #expect(model.quantization == "nvfp4")
        #expect(model.isVision == nil)
        #expect(EngineV2SupportedModels.isSupported(model: model))
        // Present only for a directory that carries the served template.
        let contract = try? PromptContractIdentity.compute(modelDirectory: directory)

        let port = UInt16(env["DARKBLOOM_MUSE_GLIMMER_PORT"] ?? "19131") ?? 19131
        let token = UUID().uuidString + UUID().uuidString
        let server = StandaloneServer(config: .init(port: port, host: "127.0.0.1", authToken: token,
            coordinatorURL: "http://127.0.0.1:1"), models: [model])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1800
        configuration.timeoutIntervalForResource = 1800
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let receipt = env["DARKBLOOM_MUSE_GLIMMER_RECEIPTS"].map { URL(fileURLWithPath: $0) }
        if let receipt { try Data().write(to: receipt) }
        func record(_ fields: [String: Any]) throws {
            guard let receipt else { return }
            let line = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
            let handle = try FileHandle(forWritingTo: receipt)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line + Data([10]))
        }
        func post(_ body: [String: Any], name: String) async throws -> (Int, Data) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            let started = ContinuousClock.now
            let (data, response) = try await session.data(for: request)
            let status = try #require(response as? HTTPURLResponse).statusCode
            let elapsed = ContinuousClock.now - started
            try record(["case": name, "status": status,
                        "seconds": Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
                        "body": String(decoding: data, as: UTF8.self)])
            return (status, data)
        }
        func chat(_ messages: [[String: Any]], maxTokens: Int = 768) -> [String: Any] {
            ["model": id, "messages": messages, "max_tokens": maxTokens, "stream": false]
        }
        func decoded(_ data: Data) throws -> (message: [String: Any], finish: String?, usage: [String: Any]) {
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let choice = try #require((object["choices"] as? [[String: Any]])?.first)
            return (try #require(choice["message"] as? [String: Any]), choice["finish_reason"] as? String,
                    object["usage"] as? [String: Any] ?? [:])
        }
        func expectNoFraming(_ text: String?, _ name: String) {
            for marker in ["<|start|>", "<|message|>", "<|eom|>", "<|eot|>", "to=self", "to=user", "<atem:"] {
                #expect(text?.contains(marker) != true, "\(name): \(marker)")
            }
        }

        try await server.start()
        do {
            try #require(await server.waitUntilBound(timeoutSeconds: 10))
            let question: [[String: Any]] = [["role": "user", "content": "What is 17 times 23? Answer with the number."]]

            let (status, data) = try await post(chat(question), name: "arithmetic")
            try #require(status == 200, "cold response: \(String(decoding: data, as: UTF8.self))")
            try #require(await server.slots[id]?.bridge.kvBackendKind == .paged, "the slot must be paged")
            let first = try decoded(data)
            let answer = first.message["content"] as? String
            let reasoning = first.message["reasoning_content"] as? String
            #expect(answer?.contains("391") == true)
            #expect(reasoning?.isEmpty == false)
            expectNoFraming(answer, "content")
            expectNoFraming(reasoning, "reasoning_content")
            #expect(first.finish == "stop")
            #expect((first.usage["completion_tokens"] as? Int ?? 0) > 0)
            try record(["case": "slot", "kv_backend": "paged", "prompt_contract_id": contract ?? "none",
                        "weight_hash_present": model.weightHash?.isEmpty == false])

            // The same prompt again: what the prefix cache reports for it.
            let (repeatStatus, repeatData) = try await post(chat(question), name: "arithmetic-repeat")
            #expect(repeatStatus == 200)
            let repeated = try decoded(repeatData)
            let details = repeated.usage["prompt_tokens_details"] as? [String: Any]
            try record(["case": "prefix-reuse", "cached_tokens": details?["cached_tokens"] as? Int ?? 0,
                        "prompt_tokens": repeated.usage["prompt_tokens"] as? Int ?? 0])

            var streamed = chat(question)
            streamed["stream"] = true
            streamed["stream_options"] = ["include_usage": true]
            let (streamStatus, streamData) = try await post(streamed, name: "stream")
            let stream = String(decoding: streamData, as: UTF8.self)
            #expect(streamStatus == 200 && stream.contains("[DONE]") && stream.contains("391"))
            #expect(stream.contains("\"reasoning_content\""))
            expectNoFraming(stream, "stream")

            // Cut inside reasoning: reasoning only, finish reason length.
            let (cutStatus, cutData) = try await post(chat(question, maxTokens: 8), name: "cut-in-reasoning")
            #expect(cutStatus == 200)
            let cut = try decoded(cutData)
            #expect(cut.finish == "length")
            expectNoFraming(cut.message["content"] as? String, "cut content")
            expectNoFraming(cut.message["reasoning_content"] as? String, "cut reasoning")

            let tool: [String: Any] = ["type": "function", "function": [
                "name": "get_weather", "description": "Get the current weather in a city.",
                "parameters": ["type": "object", "properties": ["city": ["type": "string"]],
                               "required": ["city"]]]]
            var called = chat([["role": "user", "content": "Use get_weather to check the weather in Paris. Do not guess."]])
            called["tools"] = [tool]
            let (toolStatus, toolData) = try await post(called, name: "tool-auto")
            try #require(toolStatus == 200, "tool response: \(String(decoding: toolData, as: UTF8.self))")
            let toolTurn = try decoded(toolData)
            let calls = toolTurn.message["tool_calls"] as? [[String: Any]] ?? []
            #expect(calls.count == 1)
            let function = calls.first?["function"] as? [String: Any]
            #expect(function?["name"] as? String == "get_weather")
            #expect((function?["arguments"] as? String)?.contains("Paris") == true)
            #expect(toolTurn.finish == "tool_calls")
            expectNoFraming(toolTurn.message["content"] as? String, "tool content")

            // The tool result goes back through the template's history path.
            let callID = calls.first?["id"] as? String ?? "call_1"
            var followUp = chat([
                ["role": "user", "content": "Use get_weather to check the weather in Paris. Do not guess."],
                ["role": "assistant", "content": NSNull(), "tool_calls": calls],
                ["role": "tool", "tool_call_id": callID, "content": "{\"temp_c\": 18, \"sky\": \"clear\"}"],
            ])
            followUp["tools"] = [tool]
            let (followStatus, followData) = try await post(followUp, name: "tool-result")
            try #require(followStatus == 200, "follow-up: \(String(decoding: followData, as: UTF8.self))")
            let final = try decoded(followData)
            #expect((final.message["content"] as? String)?.contains("18") == true)
            expectNoFraming(final.message["content"] as? String, "follow-up content")
        } catch {
            await server.stopAndWait()
            throw error
        }
        await server.stopAndWait()
    }
}
