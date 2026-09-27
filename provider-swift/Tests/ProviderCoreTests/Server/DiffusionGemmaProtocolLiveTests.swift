import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import ProviderCoreFoundation
import Testing

@testable import ProviderCore

private final class DiffusionProtocolBundleAnchor: NSObject {}

/// Opt-in full-artifact protocol proof, not hosted certification or a benchmark.
@Suite("DiffusionGemma live tool protocols", .serialized)
struct DiffusionGemmaProtocolLiveTests {
    private final class RawCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var rows = [String: String]()
        func append(id: String, text: String) { lock.withLock { rows[id, default: ""] += text } }
        func reset() { lock.withLock { rows.removeAll() } }
        func snapshot() -> [String: String] { lock.withLock { rows } }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_DIFFUSION_PROTOCOL_LIVE"] == "1"))
    func streamingCallsAndResponsesHistoryPreserveNativeChannels() async throws {
        let modelID = "mlx-community/diffusiongemma-26B-A4B-it-4bit"
        let directory = try #require(ModelScanner.resolveLocalPath(modelID: modelID))
        let selectedPath = ProcessInfo.processInfo.environment["DARKBLOOM_DIFFUSION_MODEL_DIR"]
        let selected = try #require(selectedPath)
        try #require(directory.appendingPathComponent("config.json").resolvingSymlinksInPath()
            == URL(fileURLWithPath: selected).appendingPathComponent("config.json").resolvingSymlinksInPath())
        try #require(!FileManager.default.fileExists(atPath: LegacyKVCacheSweeper.defaultKVRoot().path))
        _ = Bundle(for: DiffusionProtocolBundleAnchor.self).bundleURL
        let model = try #require(ModelScanner.parseModelInfo(snapshotDir: directory, modelName: modelID))
        let token = UUID().uuidString + UUID().uuidString
        let server = StandaloneServer(config: .init(authToken: token,
            coordinatorURL: "http://127.0.0.1:1"), models: [model])
        await server.activateDiffusionRouterHarness()
        do {
            // Normal load/admission, with a debug-only synthetic-output observer.
            // Does not change seed, sampling, prompt, parser or public error text.
            try await server.ensureModelLoaded(modelID)
            let raw = RawCapture()
            try await server.observeDiffusionProtocolText(modelID: modelID) { id, text in raw.append(id: id, text: text) }
            try await server.makeApplication().test(.ahc()) { client in
                try #require(client.port != nil, "Exercise actual authenticated loopback HTTP/SSE")
                let function: [String: Any] = ["name": "get_weather",
                    "description": "Get the current weather for a city.", "parameters": [
                        "type": "object", "properties": ["city": ["type": "string"]],
                        "required": ["city"], "additionalProperties": false]]
                let prompt = "Use get_weather to check the current weather in Paris. Do not guess the weather."
                for thinking in [false, true] {
                    let chat: [String: Any] = ["model": modelID,
                        "messages": [["role": "user", "content": prompt]],
                        "tools": [["type": "function", "function": function]],
                        "tool_choice": "required", "parallel_tool_calls": false,
                        "reasoning": ["enabled": thinking], "temperature": 1, "seed": 7419,
                        "max_tokens": 512, "stream": true, "stream_options": ["include_usage": true]]
                    try await client.execute(uri: "/v1/chat/completions", method: .post,
                        headers: [.contentType: "application/json", .authorization: "Bearer \(token)"],
                        body: ByteBuffer(data: JSONSerialization.data(withJSONObject: chat))) { response in
                        try #require(response.status == .ok, "Chat SSE rejected")
                        let frames = try Self.frames(String(buffer: response.body))
                        #expect(frames.doneCount == 1)
                        var name = "", arguments = "", id = "", content = "", thought = ""
                        var finishes = [String](), usageCount = 0
                        for frame in frames.json {
                            #expect(frame["error"] == nil)
                            if let usage = frame["usage"] as? [String: Any] {
                                usageCount += 1
                                #expect((usage["completion_tokens"] as? Int ?? 0) > 0)
                            }
                            for choice in frame["choices"] as? [[String: Any]] ?? [] {
                                if let finish = choice["finish_reason"] as? String { finishes.append(finish) }
                                let delta = choice["delta"] as? [String: Any] ?? [:]
                                content += delta["content"] as? String ?? ""
                                thought += delta["reasoning_content"] as? String ?? ""
                                for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                                    #expect(call["index"] as? Int == 0)
                                    if let value = call["id"] as? String { id += value }
                                    let function = call["function"] as? [String: Any] ?? [:]
                                    name += function["name"] as? String ?? ""
                                    arguments += function["arguments"] as? String ?? ""
                                }
                            }
                        }
                        #expect(finishes == ["tool_calls"] && usageCount == 1)
                        #expect(!id.isEmpty && name == "get_weather")
                        try Self.checkArguments(arguments)
                        #expect(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if !thinking { #expect(thought.isEmpty) }
                        print("DIFFUSION_PROTOCOL chat-sse thinking=\(thinking) calls=1 terminal=1")
                    }
                    for stream in [false, true] {
                        raw.reset()
                        var responseTool = function
                        responseTool["type"] = "function"
                        let request: [String: Any] = ["model": modelID, "input": prompt,
                            "tools": [responseTool], "tool_choice": "required", "parallel_tool_calls": false,
                            "reasoning": ["effort": thinking ? "medium" : "none"],
                            "temperature": 1, "max_output_tokens": 512, "stream": stream, "store": false]
                        let result = try await client.execute(uri: "/v1/responses", method: .post,
                            headers: [.contentType: "application/json", .authorization: "Bearer \(token)"],
                            body: ByteBuffer(data: JSONSerialization.data(withJSONObject: request)))
                        #expect(result.status == .ok, "Responses rejected: \(String(buffer: result.body))")
                        guard result.status == .ok else {
                            print("DIFFUSION_PROTOCOL_FAILURE " + String(decoding: try JSONSerialization.data(withJSONObject:
                                ["thinking": thinking, "stream": stream, "raw": raw.snapshot(), "status": result.status.code], options: [.sortedKeys]), as: UTF8.self))
                            print("DIFFUSION_PROTOCOL responses thinking=\(thinking) stream=\(stream) rejected=\(result.status.code) replay=not-executed")
                            continue
                        }
                        let json: [String: Any]
                        if stream {
                            let frames = try Self.frames(String(buffer: result.body)).json
                            #expect(!frames.contains { ["response.failed", "response.incomplete"].contains($0["type"] as? String ?? "") })
                            let terminals = frames.filter { $0["type"] as? String == "response.completed" }
                            #expect(terminals.count == 1)
                            guard terminals.count == 1 else {
                                print("DIFFUSION_PROTOCOL_FAILURE " + String(decoding: try JSONSerialization.data(withJSONObject:
                                    ["thinking": thinking, "stream": stream, "raw": raw.snapshot(), "frames": frames], options: [.sortedKeys]), as: UTF8.self))
                                continue
                            }
                            #expect(frames.compactMap { $0["sequence_number"] as? Int } == Array(0..<frames.count))
                            let deltas = frames.filter { $0["type"] as? String == "response.function_call_arguments.delta" }
                                .compactMap { $0["delta"] as? String }.joined()
                            try Self.checkArguments(deltas)
                            json = try #require(terminals.first?["response"] as? [String: Any])
                        } else {
                            json = try #require(try JSONSerialization.jsonObject(with: Data(result.body.readableBytesView)) as? [String: Any])
                        }
                        #expect(json["status"] as? String == "completed")
                        let output = try #require(json["output"] as? [[String: Any]])
                        let calls = output.filter { $0["type"] as? String == "function_call" }
                        try #require(calls.count == 1)
                        #expect(calls[0]["name"] as? String == "get_weather")
                        try Self.checkArguments(try #require(calls[0]["arguments"] as? String))
                        let callID = try #require(calls[0]["call_id"] as? String)
                        #expect(!callID.isEmpty)
                        let reasoning = output.filter { $0["type"] as? String == "reasoning" }
                        // Thinking ON permits an empty trained thought envelope;
                        // the separate prompt-control tests prove activation.
                        if !thinking { #expect(reasoning.isEmpty) }
                        #expect((json["output_text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        // Replay actual generated IDs and reasoning, not a fabricated history ID.
                        let input: [[String: Any]] = [["role": "user", "content": prompt]] + output + [
                            ["type": "function_call_output", "call_id": callID,
                             "output": "{\"city\":\"Paris\",\"temperature_c\":20,\"condition\":\"sunny\"}"],
                            ["role": "user", "content": "In one sentence, report the temperature and condition from the tool result."]]
                        let followup: [String: Any] = ["model": modelID, "input": input,
                            "tools": [responseTool], "tool_choice": "auto", "reasoning": ["effort": thinking ? "medium" : "none"],
                            "temperature": 1, "max_output_tokens": 512, "stream": false, "store": false]
                        let replay = try await client.execute(uri: "/v1/responses", method: .post,
                            headers: [.contentType: "application/json", .authorization: "Bearer \(token)"],
                            body: ByteBuffer(data: JSONSerialization.data(withJSONObject: followup)))
                        try #require(replay.status == .ok, "Generated Responses history failed")
                        let replayJSON = try #require(try JSONSerialization.jsonObject(with: Data(replay.body.readableBytesView)) as? [String: Any])
                        #expect(replayJSON["status"] as? String == "completed")
                        let text = replayJSON["output_text"] as? String ?? ""
                        #expect(text.contains("20") && text.lowercased().contains("sunny"))
                        #expect(!text.contains("<|channel>") && !text.contains("<channel|>"))
                        let replayOutput = replayJSON["output"] as? [[String: Any]] ?? []
                        #expect(!replayOutput.contains { $0["type"] as? String == "function_call" })
                        if !thinking { #expect(!replayOutput.contains { $0["type"] as? String == "reasoning" }) }
                        print("DIFFUSION_PROTOCOL responses thinking=\(thinking) stream=\(stream) calls=1 replay=passed")
                    }
                }
            }
        } catch {
            await server.stopAndWait()
            throw error
        }
        await server.stopAndWait()
        #expect(await server.debugActiveRequestCount(modelId: modelID) == nil)
    }

    private static func checkArguments(_ raw: String) throws {
        let arguments = try #require(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: String])
        #expect(arguments == ["city": "Paris"])
    }

    private static func frames(_ raw: String) throws -> (json: [[String: Any]], doneCount: Int) {
        var json = [[String: Any]](), done = 0
        for line in raw.components(separatedBy: "\n") where line.hasPrefix("data: ") {
            let data = String(line.dropFirst(6)).trimmingCharacters(in: .newlines)
            if data == "[DONE]" { done += 1; continue }
            json.append(try #require(try JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any]))
        }
        try #require(!json.isEmpty)
        return (json, done)
    }
}

private extension StandaloneServer {
    func observeDiffusionProtocolText(modelID: String,
        observer: @escaping @Sendable (String, String) -> Void) async throws
    {
        let bridge = try #require(slots[modelID]?.bridge)
        await bridge.observeDiffusionProtocolText(observer)
    }
}

private extension EngineV2Bridge {
    func observeDiffusionProtocolText(_ observer: @escaping @Sendable (String, String) -> Void) {
        _testNativeTextObserver = observer
    }
}
