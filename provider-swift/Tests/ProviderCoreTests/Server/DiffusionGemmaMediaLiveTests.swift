import CoreImage
import Foundation
import Hummingbird
import HummingbirdTesting
import MLX
import MLXLMCommon
import NIOCore
import ProviderCoreFoundation
import Testing

@testable import ProviderCore

private final class DiffusionMediaBundleAnchor: NSObject {}

/// Actual authenticated media ingestion, native processor/tower, CBv2 block
/// engine and API output. The explicit socket variant uses loopback only;
/// neither mode establishes hosted, attestation or encrypted-coordinator support.
@Suite("DiffusionGemma real HTTP media", .serialized)
struct DiffusionGemmaMediaLiveTests {
    private static func imageURI(_ color: CIColor) throws -> String {
        let image = CIImage(color: color).cropped(to: .init(x: 0, y: 0, width: 64, height: 64))
        let data = try #require(CIContext().pngRepresentation(of: image, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        return "data:image/png;base64," + data.base64EncodedString()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_DIFFUSION_MEDIA_HTTP_LIVE"] == "1"))
    func imagePixelsToolsAndTextHygieneUseNormalNativeServing() async throws {
        try await exerciseMedia(pageBacked: false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_DIFFUSION_PAGED_MEDIA_HTTP_LIVE"] == "1"))
    func pageBackedMediaPreservesToolsStreamingResponsesAndTextHygiene() async throws {
        try await exerciseMedia(pageBacked: true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DARKBLOOM_DIFFUSION_SOCKET_MEDIA_LIVE"] == "1"))
    func authenticatedLoopbackMediaExercisesRealHTTPAndSSE() async throws {
        try await exerciseMedia(pageBacked: true, socket: true)
    }

    private func exerciseMedia(pageBacked: Bool, socket: Bool = false) async throws {
        let modelID = "mlx-community/diffusiongemma-26B-A4B-it-4bit"
        let directory = try #require(ModelScanner.resolveLocalPath(modelID: modelID))
        let selectedPath = ProcessInfo.processInfo.environment["DARKBLOOM_DIFFUSION_MODEL_DIR"]
        let selected = try #require(selectedPath)
        try #require(directory.appendingPathComponent("config.json").resolvingSymlinksInPath()
            == URL(fileURLWithPath: selected).appendingPathComponent("config.json").resolvingSymlinksInPath())
        try #require(!FileManager.default.fileExists(atPath: LegacyKVCacheSweeper.defaultKVRoot().path))
        _ = Bundle(for: DiffusionMediaBundleAnchor.self).bundleURL
        let model = try #require(ModelScanner.parseModelInfo(snapshotDir: directory, modelName: modelID))
        try #require(model.isVision == true && model.templateRenderOK == true,
            "Native media execution must also pass discovery and multimodal template checks")
        let token = UUID().uuidString + UUID().uuidString
        let server = StandaloneServer(config: .init(authToken: token,
            engineV2KVBackend: pageBacked ? "paged" : "contiguous",
            coordinatorURL: "http://127.0.0.1:1"), models: [model])
        await server.activateDiffusionRouterHarness()
        let red = try Self.imageURI(.red), blue = try Self.imageURI(.blue)
        let video = dataURI(forMP4: try await makeSolidColorClip(colors: [
            (r: 0, g: 0, b: 255), (r: 255, g: 0, b: 0),
        ], fps: 1, width: 64, height: 64))
        let reverseVideo = dataURI(forMP4: try await makeSolidColorClip(colors: [
            (r: 255, g: 0, b: 0), (r: 0, g: 0, b: 255),
        ], fps: 1, width: 64, height: 64))
        do {
            // Hummingbird's test server binds localhost on an ephemeral port.
            // Preload for its bounded HTTP-client timeout: this is a warm
            // transport gate, not a cold-start latency measurement.
            if socket { try await server.ensureModelLoaded(modelID) }
            try await server.makeApplication().test(socket ? .live : .router) { client in
                if socket { try #require(client.port != nil) }
                let denied = try await client.execute(uri: "/v1/chat/completions", method: .post,
                    headers: [.contentType: "application/json"], body: ByteBuffer(string: "{}"))
                #expect(denied.status == .unauthorized)
                print("DIFFUSION_MEDIA_HTTP transport=\(socket ? "loopback-http" : "router") authenticated=true")
                for (kind, image) in [("red", red), ("blue", blue), ("tool", red), ("tool-on", red),
                    ("mixed", red), ("video", video), ("video-reverse", reverseVideo)] {
                    let toolCase = kind.hasPrefix("tool")
                    var content: [[String: Any]] = [["type": "image_url", "image_url": ["url": image]],
                        ["type": "text", "text": toolCase
                            ? "Use report_color to report the dominant color of this image."
                            : "Name the single dominant color of this image. Reply using only the color name."]]
                    if kind == "mixed" {
                        content = [["type": "image_url", "image_url": ["url": red]],
                            ["type": "text", "text": "This is the first image."],
                            ["type": "image_url", "image_url": ["url": blue]],
                            ["type": "text", "text": "Name the colors of the first and second image, in order. Reply: first color, second color."]]
                    }
                    if kind.hasPrefix("video") {
                        content = [["type": "video_url", "video_url": ["url": image]],
                            ["type": "text", "text": "Name the first color and then the second color shown in this video. Reply with only the two color names in order."]]
                    }
                    var request: [String: Any] = ["model": modelID,
                        "messages": [["role": "user", "content": content]], "reasoning": ["enabled": kind == "tool-on"],
                        "temperature": 1, "max_tokens": 256, "seed": 8132, "stream": false]
                    if toolCase {
                        request["tools"] = [["type": "function", "function": ["name": "report_color",
                            "description": "Record the color observed in the image.", "parameters": [
                                "type": "object", "properties": ["color": ["type": "string", "enum": ["red", "blue", "green"]]],
                                "required": ["color"], "additionalProperties": false]]]]
                        request["tool_choice"] = "required"
                        request["parallel_tool_calls"] = false
                    }
                    let response = try await client.execute(uri: "/v1/chat/completions", method: .post,
                        headers: [.contentType: "application/json", .authorization: "Bearer \(token)"],
                        body: ByteBuffer(data: JSONSerialization.data(withJSONObject: request)))
                    let json = try #require(try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any])
                    print("DIFFUSION_MEDIA_HTTP " + String(decoding: try JSONSerialization.data(
                        withJSONObject: ["case": kind, "pageBacked": pageBacked,
                            "status": response.status.code, "response": json], options: [.sortedKeys]), as: UTF8.self))
                    #expect(response.status == .ok, "Native media request failed: \(json)")
                    guard response.status == .ok else { continue }
                    let choices = try #require(json["choices"] as? [[String: Any]])
                    let message = try #require(choices.first?["message"] as? [String: Any])
                    let text = (message["content"] as? String ?? "").lowercased()
                    #expect(!text.contains("<|channel>") && !text.contains("<channel|>"))
                    if kind != "tool-on" { #expect((message["reasoning_content"] as? String ?? "").isEmpty) }
                    if toolCase {
                        let calls = try #require(message["tool_calls"] as? [[String: Any]])
                        #expect(calls.count == 1 && choices.first?["finish_reason"] as? String == "tool_calls")
                        let function = try #require(calls.first?["function"] as? [String: Any])
                        #expect(function["name"] as? String == "report_color")
                        let arguments = try #require(function["arguments"] as? String)
                        let values = try #require(try JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: String])
                        #expect(values == ["color": "red"])
                    } else if kind == "mixed" || kind.hasPrefix("video") {
                        let first = try #require(text.range(of: kind == "video" ? "blue" : "red"))
                        let second = try #require(text.range(of: kind == "video" ? "red" : "blue"))
                        #expect(first.lowerBound < second.lowerBound)
                    } else {
                        #expect(text.contains(kind) && !text.contains(kind == "red" ? "blue" : "red"))
                    }
                    if kind == "red" {
                        // Same seed, content, image and native policy: SSE must
                        // expose exactly the same committed answer and usage.
                        var streamed = request
                        streamed["stream"] = true
                        streamed["stream_options"] = ["include_usage": true]
                        let result = try await client.execute(uri: "/v1/chat/completions", method: .post,
                            headers: [.contentType: "application/json", .authorization: "Bearer \(token)"],
                            body: ByteBuffer(data: JSONSerialization.data(withJSONObject: streamed)))
                        try #require(result.status == .ok)
                        let frames = try Self.frames(String(buffer: result.body))
                        #expect(frames.done == 1)
                        var streamedText = "", finishes = [String](), usages = [[String: Any]]()
                        for frame in frames.json {
                            #expect(frame["error"] == nil)
                            if let usage = frame["usage"] as? [String: Any] { usages.append(usage) }
                            for choice in frame["choices"] as? [[String: Any]] ?? [] {
                                let delta = choice["delta"] as? [String: Any] ?? [:]
                                streamedText += delta["content"] as? String ?? ""
                                #expect((delta["reasoning_content"] as? String ?? "").isEmpty)
                                #expect(delta["tool_calls"] == nil)
                                if let finish = choice["finish_reason"] as? String { finishes.append(finish) }
                            }
                        }
                        #expect(streamedText == message["content"] as? String)
                        #expect(finishes == ["stop"] && usages.count == 1)
                        let plainUsage = try #require(json["usage"] as? [String: Any])
                        #expect(usages.first?["completion_tokens"] as? Int == plainUsage["completion_tokens"] as? Int)
                        #expect(usages.first?["prompt_tokens"] as? Int == plainUsage["prompt_tokens"] as? Int)
                        print("DIFFUSION_MEDIA_HTTP chat-sse exact=true pageBacked=\(pageBacked)")
                    }
                }
                // Responses does not expose the Chat seed control. Qualify
                // native image routing, semantics and terminal events, without
                // claiming unbound random trajectories are byte-identical.
                for stream in [false, true] {
                    let request: [String: Any] = ["model": modelID,
                        "input": [["role": "user", "content": [
                            ["type": "input_image", "image_url": red],
                            ["type": "input_text", "text": "Name the single dominant color of this image. Reply using only the color name."]]]],
                        "reasoning": ["effort": "none"], "temperature": 1,
                        "max_output_tokens": 256, "stream": stream, "store": false]
                    let result = try await client.execute(uri: "/v1/responses", method: .post,
                        headers: [.contentType: "application/json", .authorization: "Bearer \(token)"],
                        body: ByteBuffer(data: JSONSerialization.data(withJSONObject: request)))
                    try #require(result.status == .ok, "Native image Responses failed: \(String(buffer: result.body))")
                    let json: [String: Any]
                    if stream {
                        let frames = try Self.frames(String(buffer: result.body)).json
                        #expect(!frames.contains { ["response.failed", "response.incomplete"].contains($0["type"] as? String ?? "") })
                        #expect(frames.compactMap { $0["sequence_number"] as? Int } == Array(0..<frames.count))
                        let terminals = frames.filter { $0["type"] as? String == "response.completed" }
                        try #require(terminals.count == 1)
                        json = try #require(terminals[0]["response"] as? [String: Any])
                        let deltas = frames.filter { $0["type"] as? String == "response.output_text.delta" }
                            .compactMap { $0["delta"] as? String }.joined()
                        #expect(deltas == json["output_text"] as? String)
                    } else {
                        json = try #require(try JSONSerialization.jsonObject(with: Data(result.body.readableBytesView)) as? [String: Any])
                    }
                    #expect(json["status"] as? String == "completed")
                    let text = (json["output_text"] as? String ?? "").lowercased()
                    #expect(text.contains("red") && !text.contains("blue"), "Image Responses: \(json)")
                    #expect(!text.contains("<|channel>") && !text.contains("<channel|>"))
                    let output = json["output"] as? [[String: Any]] ?? []
                    #expect(!output.contains { ["reasoning", "function_call"].contains($0["type"] as? String ?? "") })
                    print("DIFFUSION_MEDIA_HTTP responses-image stream=\(stream) pageBacked=\(pageBacked) observed=\(json)")
                }
                if pageBacked { try #require(await server.diffusionMediaPageOwner(modelID)) }
                let request: [String: Any] = ["model": modelID,
                    "messages": [["role": "user", "content": "What is 2+2? Reply with the digit only."]],
                    "reasoning": ["enabled": false], "temperature": 1, "seed": 8132, "max_tokens": 64]
                let response = try await client.execute(uri: "/v1/chat/completions", method: .post,
                    headers: [.contentType: "application/json", .authorization: "Bearer \(token)"],
                    body: ByteBuffer(data: JSONSerialization.data(withJSONObject: request)))
                #expect(response.status == .ok)
                let json = try #require(try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any])
                let choices = try #require(json["choices"] as? [[String: Any]])
                let message = try #require(choices.first?["message"] as? [String: Any])
                #expect((message["content"] as? String ?? "").contains("4"))
                for limit in [1, 2] {
                    var short = request
                    short["max_tokens"] = limit
                    let response = try await client.execute(uri: "/v1/chat/completions", method: .post,
                        headers: [.contentType: "application/json", .authorization: "Bearer \(token)"],
                        body: ByteBuffer(data: JSONSerialization.data(withJSONObject: short)))
                    try #require(response.status == .ok)
                    let value = try #require(try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any])
                    let choices = try #require(value["choices"] as? [[String: Any]])
                    let message = try #require(choices.first?["message"] as? [String: Any])
                    let content = message["content"] as? String ?? ""
                    #expect(!content.contains("<|channel>") && !content.contains("<channel|>"))
                    #expect(choices.first?["finish_reason"] as? String == "length")
                    let usage = try #require(value["usage"] as? [String: Any])
                    #expect(usage["completion_tokens"] as? Int == limit)
                    print("DIFFUSION_MEDIA_HTTP length-boundary=\(limit) verified")
                }
            }
        } catch {
            await server.stopAndWait()
            throw error
        }
        await server.stopAndWait()
        #expect(await server.debugActiveRequestCount(modelId: modelID) == nil)
        #expect(await server.debugOutstandingKVReservationBytes() == 0)
    }

    private static func frames(_ raw: String) throws -> (json: [[String: Any]], done: Int) {
        var json = [[String: Any]](), done = 0
        for line in raw.components(separatedBy: "\n") where line.hasPrefix("data: ") {
            let value = String(line.dropFirst(6)).trimmingCharacters(in: .newlines)
            if value == "[DONE]" { done += 1; continue }
            json.append(try #require(try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any]))
        }
        try #require(!json.isEmpty)
        return (json, done)
    }
}

private extension StandaloneServer {
    func diffusionMediaPageOwner(_ modelID: String) async -> Bool {
        guard let bridge = slots[modelID]?.bridge else { return false }
        return await bridge.diffusionMediaPageOwner()
    }
}

private extension EngineV2Bridge {
    func diffusionMediaPageOwner() -> Bool {
        guard let engine = ownedEngine as? CBv2NativeBlockEngine else { return false }
        return engine.usesPagedStorage && engine.usesProcessMemoryOwner
    }
}
