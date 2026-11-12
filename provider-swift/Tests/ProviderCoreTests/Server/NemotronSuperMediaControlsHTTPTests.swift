// Copyright © 2026 Eigen Labs.
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import MLXLMCommon
@testable import MLXVLM
import NIOCore
import Testing
@testable import ProviderCore

/// Live loopback HTTP through the Super hook's media route on the actual
/// native bridge, image tower and video decoder with tiny synthetic weights.
/// The scripted tokenizer renders the pinned template (recording the prompt)
/// and maps the N-th generated token to the N-th script piece, so the media
/// route's structured output and tool calls are exact. Media requests take
/// the same request plan as text: its response format, tools, tool choice,
/// `parallel_tool_calls` and `min_p`.
@Suite(.serialized)
struct NemotronSuperMediaControlsHTTPTests {
    private static var weather: [String: Any] { ["type": "function", "function": ["name": "get_weather",
        "parameters": ["type": "object", "properties": ["city": ["type": "string"]], "required": ["city"]]]] }
    private static let call = ["Use tool.", "</think>", "<tool_call>", "\n<function=get_weather>",
                               "\n<parameter=city>", "\nParis", "\n</parameter>", "\n</function>", "\n</tool_call>"]
    private static let twoCalls = call + ["\n<tool_call>", "\n<function=get_weather>", "\n<parameter=city>",
                                          "\nRome", "\n</parameter>", "\n</function>", "\n</tool_call>"]
    private static var schema: [String: Any] { ["type": "json_schema", "json_schema": ["name": "r",
        "schema": ["type": "object", "properties": ["ok": ["type": "boolean"]], "required": ["ok"]]]] }

    /// One inline media part: its content-part type and data URI.
    private struct Media: Sendable {
        let part: String
        let uri: String
    }

    @Test(.timeLimit(.minutes(4))) func mediaRequestsServeStructuredOutputToolsAndSettings() async throws {
        let dimensions = NemotronRadioDimensions(width: 2, layers: 1, heads: 1,
            channels: 3, patch: 16, positionSide: 32, prefix: 1, mlpWidth: 3)
        let (installed, construction, residency) = try SuperInstalledFixture(radioDimensions: dimensions).make()
        let budget = GlobalKVCacheBudget(capFraction: 1, activationReserveBytes: 0,
            memorySnapshot: { .init(total: 16 << 30, active: 0, cache: 0, systemAvailable: .max) })
        let lease = try #require(await budget.claimPendingLoad(requestID: "super-media-controls-http",
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
        let token = "synthetic-super-media-controls"
        let app = makeLocalInferenceApplication(
            config: .init(host: "127.0.0.1", port: 0, authToken: token), defaultMaxTokens: 16,
            acquire: { id in throw MultiModelBatchSchedulerEngineError.modelNotLoaded(id) },
            tokenizerProvider: { _ in .init(tokenizer: tokenizer, modelType: "nemotron_h_omni") },
            availableModels: { [] }, mtpSlots: { [] },
            modelTypeProvider: { _ in "nemotron_h_omni" }, nemotronSuperImageHTTP: hook)
        let headers: HTTPFields = [.contentType: "application/json", .authorization: "Bearer " + token]
        let png = try NemotronSuperImageFixtures.data("png-rgb8.png")
        let image = Media(part: "image_url", uri: "data:image/png;base64," + png.base64EncodedString())
        // A square clip maps to the 32 x 32 patch grid the fixture tower covers.
        let clip = try await MiMoEncodedMediaFixtures.video(frames: 10, fps: 4, width: 64, height: 64)
        let video = Media(part: "video_url", uri: "data:video/mp4;base64," + clip.base64EncodedString())
        @Sendable func body(_ media: Media, _ pieces: [String], stream: Bool,
                            _ extra: [String: Any] = [:]) throws -> ByteBuffer {
            script.set(pieces)
            let part: [String: Any] = ["type": media.part, media.part: ["url": media.uri]]
            var value: [String: Any] = ["model": NemotronSuperLocalBinding.modelID, "stream": stream,
                "temperature": 0, "max_tokens": pieces.count,
                "messages": [["role": "system", "content": "Be brief."],
                             ["role": "user", "content": [["type": "text", "text": "Describe it."], part]]]]
            value.merge(extra) { _, new in new }
            return ByteBuffer(bytes: try JSONSerialization.data(withJSONObject: value))
        }
        /// A tool result that carries the media: the assistant's call, then
        /// the tool's answer as a content part.
        @Sendable func toolResultBody(_ media: Media, _ pieces: [String]) throws -> ByteBuffer {
            script.set(pieces)
            let part: [String: Any] = ["type": media.part, media.part: ["url": media.uri]]
            let call: [String: Any] = ["id": "call-1", "type": "function",
                                       "function": ["name": "get_weather", "arguments": #"{"city":"Paris"}"#]]
            let value: [String: Any] = ["model": NemotronSuperLocalBinding.modelID, "stream": false,
                "temperature": 0, "max_tokens": pieces.count, "tools": [Self.weather],
                "messages": [["role": "user", "content": "What does the weather camera show?"],
                             ["role": "assistant", "content": NSNull(), "tool_calls": [call]],
                             ["role": "tool", "tool_call_id": "call-1", "content": [part]]]]
            return ByteBuffer(bytes: try JSONSerialization.data(withJSONObject: value))
        }
        let baseline = await budget.outstandingReservedBytes()
        try await app.test(.live) { client in
            func send(_ buffer: ByteBuffer, status: HTTPResponse.Status = .ok) async throws -> String {
                try await client.execute(uri: "/v1/chat/completions", method: .post,
                    headers: headers, body: buffer) { response in
                    let text = String(buffer: response.body)
                    #expect(response.status == status, "\(text)")
                    return text
                }
            }
            for (name, media) in [("image", image), ("video", video)] {
                // JSON output, first: the format's instruction reaches the
                // media prompt and the answer is withheld and validated.
                let json = try SuperJSON(try await send(body(media, ["{\"ok\"", ": true}"], stream: false,
                    ["enable_thinking": false, "response_format": ["type": "json_object"]])))
                #expect(json.content == #"{"ok": true}"#, "\(name)")
                #expect(script.prompt.contains("You must respond with a single valid JSON object."), "\(name)")
                #expect(script.prompt.contains("<image>"), "\(name): the media slot is rendered")
                let streamed = SuperSSE(try await send(body(media, ["think", "</think>", "{\"ok\":", " true}"],
                    stream: true, ["response_format": ["type": "json_object"]])))
                #expect(streamed.reasoning == "think" && streamed.content == #"{"ok": true}"#, "\(name)")
                for stream in [true, false] {
                    let text = try await send(body(media, ["{\"ok\"", ": false}"], stream: stream,
                        ["enable_thinking": false, "response_format": Self.schema]))
                    let content = stream ? SuperSSE(text).content : try SuperJSON(text).content
                    #expect(content == #"{"ok": false}"#, "\(name) stream \(stream)")
                }
                _ = try await send(body(media, ["not", " json"], stream: false,
                    ["enable_thinking": false, "response_format": ["type": "json_object"]]),
                    status: .unprocessableContent)
                let failed = try await send(body(media, ["not", " json"], stream: true,
                    ["enable_thinking": false, "response_format": ["type": "json_object"]]))
                #expect(failed.contains(#""finish_reason":"error""#) && SuperSSE(failed).content.isEmpty, "\(name)")

                // Tools: the declaration reaches the media prompt; a call
                // leaves as validated `tool_calls`.
                for stream in [true, false] {
                    let text = try await send(body(media, Self.call, stream: stream,
                        ["tools": [Self.weather], "tool_choice": "auto", "parallel_tool_calls": false, "min_p": 0]))
                    #expect(script.prompt.contains("<name>get_weather</name>") && script.prompt.contains("<image>"),
                            "\(name)")
                    let calls = stream ? SuperSSE(text).toolCalls : try SuperJSON(text).toolCalls
                    #expect(calls.map(\.name) == ["get_weather"], "\(name) stream \(stream)")
                    #expect(calls.map(\.arguments) == [#"{"city":"Paris"}"#], "\(name) stream \(stream)")
                    #expect(text.contains(#""finish_reason":"tool_calls""#), "\(name) stream \(stream)")
                }
                let named = try await send(body(media, Self.call, stream: false, ["tools": [Self.weather],
                    "tool_choice": ["type": "function", "function": ["name": "get_weather"]]]))
                #expect(try SuperJSON(named).toolCalls.map(\.name) == ["get_weather"], "\(name)")
                #expect(script.prompt.contains("Call the declared function 'get_weather' now."), "\(name)")
                // A forced choice the answer breaks is the model's failure (422).
                _ = try await send(body(media, ["</think>", "Sure."], stream: false,
                    ["tools": [Self.weather], "tool_choice": "required"]), status: .unprocessableContent)
                // JSON output with tools: a call is a call, an answer must be JSON.
                let jsonTools: [String: Any] = ["tools": [Self.weather], "response_format": ["type": "json_object"]]
                #expect(try SuperJSON(try await send(body(media, Self.call, stream: false, jsonTools)))
                    .toolCalls.map(\.name) == ["get_weather"], "\(name)")
                let answered = try SuperJSON(try await send(body(media,
                    ["Use tool?", "</think>", "{\"city\"", ": \"Paris\"}"], stream: false, jsonTools)))
                #expect(answered.content == #"{"city": "Paris"}"#, "\(name)")
                // The prompt order: the tools block in the first system turn,
                // the format's system turn, then the user's media slot.
                let tools = try #require(script.prompt.range(of: "<name>get_weather</name>"), "\(name)")
                let format = try #require(script.prompt.range(of: "You must respond with a single valid JSON object."),
                                          "\(name)")
                let slot = try #require(script.prompt.range(of: "<image>"), "\(name)")
                #expect(tools.upperBound <= format.lowerBound && format.upperBound <= slot.lowerBound, "\(name)")
                // `tool_choice: none`: no declaration reaches the prompt, and the answer is text.
                let none = try SuperJSON(try await send(body(media, ["</think>", "Sunny."], stream: false,
                    ["tools": [Self.weather], "tool_choice": "none"])))
                #expect(none.content == "Sunny." && none.toolCalls.isEmpty, "\(name)")
                #expect(!script.prompt.contains("<name>get_weather</name>")
                    && script.prompt.contains("Do not call any tool."), "\(name)")
                // `parallel_tool_calls: false` with two calls: the model broke the contract (422).
                _ = try await send(body(media, Self.twoCalls, stream: false,
                    ["tools": [Self.weather], "parallel_tool_calls": false]), status: .unprocessableContent)
                // Media in a tool result, which `native_media_tools` advertises.
                let result = try SuperJSON(try await send(toolResultBody(media, ["</think>", "Sunny."])))
                #expect(result.content == "Sunny.", "\(name)")
                #expect(script.prompt.contains("<tool_response>\n<image>"), "\(name): \(script.prompt)")
                #expect(await budget.outstandingReservedBytes() == baseline, "\(name)")
            }
            // A control the text route refuses is refused with media as a
            // request error, not as invalid media; nothing stays reserved.
            let minP = try await send(body(image, ["x"], stream: false, ["min_p": 0.1]), status: .badRequest)
            #expect(minP.contains("Invalid inference request."), "\(minP)")
            let bias = try await send(body(image, ["x"], stream: false, ["logit_bias": ["1": 1]]), status: .badRequest)
            #expect(!bias.contains("Invalid media input."), "\(bias)")
            // Media the route does not serve is named as unsupported media:
            // here an image part whose label is not an image.
            let octets = Media(part: "image_url",
                               uri: "data:application/octet-stream;base64," + png.base64EncodedString())
            let unsupported = try await send(body(octets, ["x"], stream: false), status: .badRequest)
            #expect(unsupported.contains("Media input is not supported."), "\(unsupported)")
            #expect(await budget.outstandingReservedBytes() == baseline)
        }
        await hook.drain()
        try await owner.closeAfterDrain()
        #expect(residency.snapshot.usedBytes == 0)
        #expect(await budget.finishPendingLoad(lease))
        #expect(await budget.outstandingReservedBytes() == 0)
    }

    /// Every media-route refusal names its cause by its failure code (the
    /// coordinator shows only that code's fixed text): media the route does
    /// not serve, media above a limit, corrupt media, or a request fault.
    @Test func mediaRefusalsNameTheirCause() {
        typealias Binding = NemotronSuperLocalImageBinding
        let cases: [(any Error, InferenceFailureCode)] = [
            (Binding.Failure.unsupportedMedia(.imageSource), .unsupportedMedia),
            (Binding.Failure.unsupportedMedia(.tooManyImages), .unsupportedMedia),
            (Binding.Failure.unsupportedMedia(.audio), .unsupportedMedia),
            (Binding.Failure.unsupportedMedia(.partType), .unsupportedMedia),
            (NemotronSuperImageDecode.Failure.unsupportedEncoding, .unsupportedMedia),
            (NemotronSuperImagePreprocessing.Failure.invalidGeometry, .unsupportedMedia),
            (NemotronSuperImageDecode.Failure.sizeLimit, .mediaTooLarge),
            (NemotronSuperImagePreprocessing.Failure.workspaceLimit, .mediaTooLarge),
            (Binding.Failure.bodyTooLarge, .mediaTooLarge),
            (NemotronSuperImageDecode.Failure.invalidHeader, .invalidMedia),
            (NemotronSuperImageDecode.Failure.invalidRaster, .invalidMedia),
            (NemotronSuperImagePreprocessing.Failure.invalidPixels, .invalidMedia),
            (MediaIngest.MediaError.base64DecodeFailed, .invalidMedia),
            (Binding.Failure.placeholderText, .invalidRequest),
            (Binding.Failure.contextExceeded, .invalidRequest),
            (Binding.Failure.unsupportedCapability, .invalidRequest),
            (Binding.Failure.wrongModel, .invalidRequest),
            (NemotronSuperRequestPlan.Failure.unsupportedControl, .invalidRequest),
            (NemotronSuperPromptContract.Failure.toolDeclarationMismatch, .invalidRequest),
        ]
        for (error, code) in cases {
            let failure = ProviderLoop.sanitizedInferenceFailure(
                from: SuperHTTPErrors.map(error, media: true), phase: .request)
            #expect(failure.code == code && failure.statusCode == 400, "\(error): \(failure)")
        }
    }
}
