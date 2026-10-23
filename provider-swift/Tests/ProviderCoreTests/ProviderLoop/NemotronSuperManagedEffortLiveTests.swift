// Copyright © 2026 Eigen Labs.

import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import MLXLMCommon
import NIOCore
import Testing
@testable import ProviderCore

extension NemotronSuperManagedSlotTests {
    /// The pinned model's actual template controls, through the managed local
    /// OpenAI endpoint and encrypted coordinator path. No separate MTP binding.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_SUPER_EFFORT_LIVE"] == "1"),
          .timeLimit(.minutes(20)))
    func pinnedCheckpointEffortModesReachManagedServing() async throws {
        let (loop, _) = try await Self.liveLoop(name: "super-effort-acceptance")
        let owner = try #require(await loop.nemotronSuperOwnerForTesting(modelId: Self.modelID))
        #expect(owner.speculates)
        let engine = try #require(await owner.bridge.ownedEngine as? EngineV2)
        let bank = try #require(engine.hybridPrefixCache)
        let app = makeLocalInferenceApplication(
            config: .init(host: "127.0.0.1", port: 0, authToken: "super-effort-test"), defaultMaxTokens: 2048,
            acquire: { id in try await loop.acquireModelForLocal(id) },
            tokenizerProvider: { _ in throw MultiModelBatchSchedulerEngineError.noModelLoadedForTokenization },
            availableModels: { [Self.modelID] }, mtpSlots: { [] },
            managedSuperEngine: { body, request in
                guard request.model == Self.modelID else { return nil }
                return NemotronSuperLocalEndpointEngine(body: body, hasMedia: MediaIngest.hasMedia(request), cacheScope: "effort-http",
                    acquire: { try await loop.acquireNemotronSuperForLocal(Self.modelID) })
            })
        let body = Self.effortBody
        let modeControls: [(String, [String: Any], Bool)] = [
            ("omitted", [:], true), ("high", ["reasoning_effort": "high"], true),
            ("medium", ["reasoning_effort": "medium"], true), ("none", ["reasoning_effort": "none"], false),
            ("off", ["reasoning_effort": "off"], false), ("zero", ["reasoning_effort": "0"], false),
            ("nested-medium", ["reasoning": ["effort": " MEDIUM\n"]], true),
            ("template-medium", ["chat_template_kwargs": ["enable_thinking": true, "medium_effort": true]], true),
        ]
        // The live client closure is @Sendable: encode every body before it.
        let modes: [(name: String, thinking: Bool, bodies: [(stream: Bool, data: Data)])] = try modeControls.map {
            name, controls, thinking in
            (name, thinking, try [false, true].map { ($0, try body(controls, $0, Self.arithmeticPrompt)) })
        }
        let tool: [String: Any] = ["type": "function", "function": ["name": "get_weather",
            "parameters": ["type": "object", "properties": ["city": ["type": "string"]], "required": ["city"]]]]
        let structured: [(effort: String, stream: Bool, tool: Data, json: Data)] = try ["none", "medium", "high"]
            .flatMap { effort in try [false, true].map { stream in
                (effort, stream,
                 try body(["reasoning_effort": effort, "tools": [tool],
                     "tool_choice": ["type": "function", "function": ["name": "get_weather"]]],
                     stream, "Call get_weather for Paris."),
                 try body(["reasoning_effort": effort, "response_format": ["type": "json_object"]],
                     stream, "Return exactly one JSON object with key answer and integer value 4."))
            } }
        let invalid: [Data] = try ([["reasoning_effort": "low"], ["reasoning_effort": "xhigh"],
                                    ["reasoning_effort": "medium", "medium_effort": false],
                                    ["reasoning_effort": "high", "reasoning": ["effort": "medium"]]] as [[String: Any]])
            .map { try body($0, true, Self.arithmeticPrompt) }
        try await app.test(.live) { client in
            let headers: HTTPFields = [.contentType: "application/json", .authorization: "Bearer super-effort-test"]
            for (name, thinking, bodies) in modes {
                for (stream, data) in bodies {
                    try await client.execute(uri: "/v1/chat/completions", method: .post, headers: headers,
                        body: ByteBuffer(bytes: data)) { response in
                        #expect(response.status == .ok, "\(name) stream=\(stream)")
                        let text = String(buffer: response.body)
                        let content: String, reasoning: String
                        if stream {
                            let result = SuperSSE(text)
                            content = result.content; reasoning = result.reasoning
                            #expect(result.finishReason == "stop")
                            #expect(text.contains("data: [DONE]"))
                        } else {
                            let result = try SuperJSON(text)
                            content = result.content ?? ""; reasoning = result.reasoning ?? ""
                        }
                        #expect(content.contains("323"), "\(name): \(content)")
                        #expect(reasoning.isEmpty != thinking, "\(name) reasoning chars=\(reasoning.count)")
                        #expect(!content.contains("<think>") && !content.contains("</think>"))
                        #expect(text.contains("completion_tokens") && text.contains("prompt_tokens"))
                        print("SUPER_EFFORT_HTTP mode=\(name) stream=\(stream) thinking=\(thinking) content=\(content.debugDescription) reasoning_chars=\(reasoning.count)")
                    }
                }
            }
            for (effort, stream, toolBody, jsonBody) in structured {
                try await client.execute(uri: "/v1/chat/completions", method: .post, headers: headers,
                    body: ByteBuffer(bytes: toolBody)) { response in
                    #expect(response.status == .ok)
                    let text = String(buffer: response.body)
                    let calls = stream ? SuperSSE(text).toolCalls : try SuperJSON(text).toolCalls
                    #expect(calls.count == 1 && calls.first?.name == "get_weather")
                    let arguments = try #require(calls.first?.arguments)
                    let parsed = try JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: String]
                    #expect(parsed?["city"] == "Paris")
                    print("SUPER_EFFORT_TOOL mode=\(effort) stream=\(stream) call=get_weather city=Paris")
                }
                try await client.execute(uri: "/v1/chat/completions", method: .post, headers: headers,
                    body: ByteBuffer(bytes: jsonBody)) { response in
                    #expect(response.status == .ok)
                    let text = String(buffer: response.body)
                    let content = stream ? SuperSSE(text).content : (try SuperJSON(text).content ?? "")
                    let parsed = try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Int]
                    #expect(parsed == ["answer": 4])
                    print("SUPER_EFFORT_JSON mode=\(effort) stream=\(stream) answer=4")
                }
            }
            for data in invalid {
                try await client.execute(uri: "/v1/chat/completions", method: .post, headers: headers,
                    body: ByteBuffer(bytes: data)) { response in
                    #expect(response.status == .badRequest)
                }
            }
        }

        let recorder = Recorder(), consumer = NodeKeyPair.generate()
        let document = (1...250).map { "Fact \($0): marker \($0) is violet and weighs 50 kilograms." }.joined(separator: " ")
        let prompt = document + " What color is marker 164? Reply with one word."
        for mode in ["high", "medium", "none"] {
            let request = try body(["reasoning_effort": mode], true, prompt)
            let beforeCold = bank.stats.adoptions
            let cold = try await Self.send(request, to: loop, recorder: recorder, consumer: consumer, scope: nil, deadline: 600)
            #expect(bank.stats.adoptions == beforeCold)
            _ = try await Self.send(request, to: loop, recorder: recorder, consumer: consumer, scope: "effort-shared", deadline: 600)
            let beforeWarm = bank.stats.adoptions
            let warm = try await Self.send(request, to: loop, recorder: recorder, consumer: consumer, scope: "effort-shared", deadline: 600)
            #expect(bank.stats.adoptions > beforeWarm)
            let a = SuperSSE(cold.sse), b = SuperSSE(warm.sse)
            #expect(a.content == b.content && a.reasoning == b.reasoning)
            #expect(a.content.lowercased().contains("violet"))
            let coldUsage = try #require(Self.usage(cold.terminal)), warmUsage = try #require(Self.usage(warm.terminal))
            #expect(coldUsage.promptTokens == warmUsage.promptTokens && coldUsage.completionTokens == warmUsage.completionTokens)
            print("SUPER_EFFORT_CACHE mode=\(mode) prompt=\(warmUsage.promptTokens) completion=\(warmUsage.completionTokens) adoptions=\(bank.stats.adoptions) tokens_saved=\(bank.stats.tokensSaved) exact=true")
        }
        let mtp = await owner.bridge.mtpStatusSnapshot()
        #expect(mtp.active && mtp.rounds > 0)
        #expect(await loop.unloadModel(Self.modelID))
        #expect(bank.stats.retainedBytes == 0)
        try await Self.awaitMemoryReturn(loop)
    }

    static let arithmeticPrompt = "What is 17 times 19? Reply with the number only."

    static func effortBody(_ controls: [String: Any], _ stream: Bool, _ prompt: String) throws -> Data {
        var value: [String: Any] = ["model": modelID, "stream": stream, "temperature": 0,
            "max_tokens": 2048, "messages": [["role": "user", "content": prompt]]]
        if stream { value["stream_options"] = ["include_usage": true] }
        value.merge(controls) { _, new in new }
        return try JSONSerialization.data(withJSONObject: value)
    }
}
