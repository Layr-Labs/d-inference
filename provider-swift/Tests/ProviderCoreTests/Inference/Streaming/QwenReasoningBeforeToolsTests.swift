// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// One engine row that says `chunks`, one delta each (the test tokenizer's
/// tokens), then ends with `finish`.
private final class ScriptedQwenEngine: CBv2Engine, @unchecked Sendable {
    let chunks: [String]
    let finish: CBv2FinishReason

    init(chunks: [String], finish: CBv2FinishReason) {
        self.chunks = chunks
        self.finish = finish
    }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        var completion = 0
        for chunk in chunks where !chunk.isEmpty {
            let tokens = QwenByteTestTokenizer.tokens(chunk)
            completion += tokens.count
            continuation.yield(.delta(text: chunk, tokens: tokens, logprobs: nil))
        }
        continuation.yield(.finished(reason: finish,
            usage: CBv2Usage(promptTokens: request.promptTokens.count, completionTokens: completion)))
        continuation.finish()
        return stream
    }

    func cancel(_ id: CBv2RequestID) {}

    func capacity() -> CBv2CapacitySnapshot {
        .init(activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0, kvBytesCapacity: 0, activeTokens: 0)
    }

    func shutdown() async {}
}

/// How generated text reaches the scheduler: whole, one character per delta,
/// or cut in the middle of every think and tool marker.
private enum Chunking: String, CaseIterable {
    case whole, characters, threes, markerHalves

    private static let markers = ["<think>", "</think>", "<tool_call>", "</tool_call>", "<function=", "</function>"]

    func split(_ text: String) -> [String] {
        switch self {
        case .whole:
            return [text]
        case .characters:
            return text.map(String.init)
        case .threes:
            let characters = Array(text)
            return stride(from: 0, to: characters.count, by: 3).map {
                String(characters[$0..<min($0 + 3, characters.count)])
            }
        case .markerHalves:
            var cuts: [String.Index] = []
            for marker in Self.markers {
                var from = text.startIndex
                while let range = text.range(of: marker, range: from..<text.endIndex) {
                    cuts.append(text.index(range.lowerBound, offsetBy: marker.count / 2))
                    from = range.upperBound
                }
            }
            var pieces: [String] = []
            var start = text.startIndex
            for cut in cuts.sorted() where cut > start {
                pieces.append(String(text[start..<cut]))
                start = cut
            }
            pieces.append(String(text[start...]))
            return pieces
        }
    }
}

/// What a client receives, from the SSE frames or the collected response.
private struct Served: CustomStringConvertible {
    struct Call: CustomStringConvertible {
        var name: String
        var arguments: String
        var description: String { "\(name)(\(arguments))" }
    }

    var content = ""
    var reasoning = ""
    var calls: [Call] = []
    /// SSE frames that carried a tool-call fragment (streamed responses only).
    var toolFrames = 0
    var finishReason: String?
    var error: String?

    var description: String {
        "content=\(content.debugDescription) reasoning=\(reasoning.debugDescription) calls=\(calls) "
            + "finish=\(finishReason ?? "nil") error=\(error ?? "nil")"
    }
}

/// A production Qwen 3.5-family build: the catalog id and its `model_type`.
struct QwenToolBuild: CustomTestStringConvertible, Sendable {
    let id: String
    let modelType: String
    var testDescription: String { id }
}

/// One raw model output (after the prompt's own `<think>\n`, or after its
/// closed block when thinking is off) and what the client must receive.
struct QwenToolOutputCase: CustomTestStringConvertible, Sendable {
    enum Choice: Sendable { case auto, required, named, thinkingOff }

    let name: String
    let output: String
    var choice: Choice = .auto
    var lengthStop = false
    /// Expected calls: name and arguments as a JSON object string.
    let calls: [(String, String)]
    /// Expected visible content, ignoring surrounding whitespace.
    var content = ""
    /// Expected reasoning, ignoring surrounding whitespace (nil: not checked).
    var reasoning: String?

    var testDescription: String { name }
}

@Suite("Qwen 3.5-family reasoning is classified before tool parsing (scheduler text path)")
struct QwenReasoningBeforeToolsTests {
    private static let tokenizer = TokenizerHandle(QwenByteTestTokenizer())

    static let builds = [
        QwenToolBuild(id: "EigenLabs/Qwen3.8-27B-4bit-mtp", modelType: "qwen3_5"),
        QwenToolBuild(id: "Qwen3.5-9B", modelType: "qwen3_5"),
        QwenToolBuild(id: "qwen3.6-35b-a3b-vl-mtp-mxfp8", modelType: "qwen3_5_moe"),
        QwenToolBuild(id: "qwen3.5-35b-a3b", modelType: "qwen3_5_moe"),
    ]

    private static var tools: [[String: Any]] { [
        ["type": "function", "function": [
            "name": "get_weather", "description": "Get the current weather for a city.",
            "parameters": ["type": "object", "required": ["location"], "properties": [
                "location": ["type": "string"],
                "unit": ["type": "string", "enum": ["celsius", "fahrenheit"]],
            ] as [String: Any]] as [String: Any],
        ] as [String: Any]],
        ["type": "function", "function": [
            "name": "save_note", "description": "Save a note.",
            "parameters": ["type": "object", "required": ["title", "body"], "properties": [
                "title": ["type": "string"],
                "body": ["type": "string"],
                "tags": ["type": "array", "items": ["type": "string"]],
            ] as [String: Any]] as [String: Any],
        ] as [String: Any]],
    ] }

    static func call(_ city: String, unit: String? = nil) -> String {
        "<tool_call>\n<function=get_weather>\n<parameter=location>\n\(city)\n</parameter>\n"
            + (unit.map { "<parameter=unit>\n\($0)\n</parameter>\n" } ?? "") + "</function>\n</tool_call>"
    }

    static func weather(_ city: String, unit: String? = nil) -> (String, String) {
        ("get_weather", unit.map { #"{"location":"\#(city)","unit":"\#($0)"}"# } ?? #"{"location":"\#(city)"}"#)
    }

    /// CONFORMANCE's replay cases (`replay/out/qwen38*`) and the shapes around them.
    static let cases: [QwenToolOutputCase] = [
        .init(name: "a call after a thought",
              output: "Let me check the weather.\n</think>\n\n" + call("Zürich", unit: "celsius"),
              calls: [weather("Zürich", unit: "celsius")], reasoning: "Let me check the weather."),
        .init(name: "a lone <tool_call> mentioned in the thought, then the call",
              output: "I should wrap it in <tool_call> tags.\n</think>\n\n" + call("Bern"),
              calls: [weather("Bern")], reasoning: "I should wrap it in <tool_call> tags."),
        .init(name: "the tag mentioned in backticks, then the call",
              output: "Format: `<tool_call>` then `<function=...>`.\n</think>\n\n" + call("Bern"),
              calls: [weather("Bern")], reasoning: "Format: `<tool_call>` then `<function=...>`."),
        .init(name: "<tool_call> and <function=…> mentioned, then the call",
              output: "The format is <tool_call> with <function=name> inside; I will use it.\n</think>\n\n"
                  + call("Bern"),
              calls: [weather("Bern")]),
        .init(name: "only <function=…> mentioned, then the call",
              output: "Use the <function=get_weather> block.\n</think>\n\n" + call("Bern"), calls: [weather("Bern")]),
        .init(name: "only </tool_call> mentioned, then the call",
              output: "End with </tool_call> after the call.\n</think>\n\n" + call("Bern"), calls: [weather("Bern")]),
        .init(name: "both tags mentioned, then the call",
              output: "Format: <tool_call> ... </tool_call>.\n</think>\n\n" + call("Bern"), calls: [weather("Bern")]),
        .init(name: "a call drafted in the thought, then the real call",
              output: "I'll call " + call("Paris") + " to get it.\n</think>\n\n" + call("Zürich"),
              calls: [weather("Zürich")], reasoning: "I'll call " + call("Paris") + " to get it."),
        .init(name: "a call written only in the thought, then a text answer",
              output: "I'll call " + call("Paris") + " later.\n</think>\n\nI can't check the weather right now.",
              calls: [], content: "I can't check the weather right now.",
              reasoning: "I'll call " + call("Paris") + " later."),
        .init(name: "a call drafted in a thought cut off by the token limit",
              output: "Maybe " + call("Paris") + " but I am still thinking", lengthStop: true,
              calls: [], reasoning: "Maybe " + call("Paris") + " but I am still thinking"),
        .init(name: "two calls after a lone mentioned tag",
              output: "Two cities, each in its own <tool_call> block.\n</think>\n\n" + call("Zürich") + "\n"
                  + call("Paris"),
              calls: [weather("Zürich"), weather("Paris")]),
        .init(name: "two calls",
              output: "Two cities.\n</think>\n\n" + call("Zürich") + "\n" + call("Paris"),
              calls: [weather("Zürich"), weather("Paris")]),
        .init(name: "a text answer after a thought that mentions the tag",
              output: "The <tool_call> syntax is not needed.\n</think>\n\nZürich is cool.",
              calls: [], content: "Zürich is cool.", reasoning: "The <tool_call> syntax is not needed."),
        .init(name: "an answer that mentions the tag",
              output: "Simple.\n</think>\n\nTo call a tool, write <tool_call> followed by the function block.",
              calls: [], content: "To call a tool, write <tool_call> followed by the function block."),
        .init(name: "a thought that never closes",
              output: "I keep thinking about this and never close the block", lengthStop: true,
              calls: [], reasoning: "I keep thinking about this and never close the block"),
        .init(name: "arguments that spell think markers stay arguments",
              output: "Saving it.\n</think>\n\n<tool_call>\n<function=save_note>\n<parameter=title>\nTags\n</parameter>\n"
                  + "<parameter=body>\nwrite </think> then <think> literally\n</parameter>\n"
                  + "<parameter=tags>\n[\"a\", \"b\"]\n</parameter>\n</function>\n</tool_call>",
              calls: [("save_note", #"{"title":"Tags","body":"write </think> then <think> literally","tags":["a","b"]}"#)]),
        .init(name: "thinking off: a call", output: call("Bern"), choice: .thinkingOff, calls: [weather("Bern")]),
        .init(name: "thinking off: a stray thought that mentions the tag, then the call",
              output: "<think>\nWrap it in <tool_call> tags.\n</think>\n\n" + call("Bern"), choice: .thinkingOff,
              calls: [weather("Bern")], reasoning: "Wrap it in <tool_call> tags."),
        .init(name: "thinking off: a text answer", output: "Zürich is cool in November.", choice: .thinkingOff,
              calls: [], content: "Zürich is cool in November."),
        .init(name: "required: a call", output: call("Bern"), choice: .required, calls: [weather("Bern")]),
        .init(name: "named: a call", output: call("Bern"), choice: .named, calls: [weather("Bern")]),
        .init(name: "required: a stray thought that mentions the tag, then the call",
              output: "<think>\nWrap it in <tool_call> tags.\n</think>\n\n" + call("Bern"), choice: .required,
              calls: [weather("Bern")], reasoning: "Wrap it in <tool_call> tags."),
    ]

    /// The route is the Qwen 3.5 types' alone: native families keep their own, other Qwen types the raw one,
    /// and `auto` calls keep streaming (their deltas key on the native-channel predicate, which stays false).
    @Test func routingIsScopedToTheQwen35Types() {
        for build in Self.builds {
            let context = ChatTemplateFixContext(modelId: build.id, modelType: build.modelType)
            #expect(ToolChoiceEnforcementPolicy.splitsQwenReasoningBeforeTools(context))
            #expect(!ToolChoiceEnforcementPolicy.usesNativeTextChannels(context))
        }
        for modelType in ["qwen3_next", "qwen3_vl_moe", "qwen3", "prism_hadamard_qwen35", "qwen4_exp", "gemma4",
                          "glm5_next", "gpt_oss", "mimo_v2", "nemotron_h", "llama", "Qwen3_5", " qwen3_5"] {
            #expect(!ToolChoiceEnforcementPolicy.splitsQwenReasoningBeforeTools(
                .init(modelId: "EigenLabs/Qwen3.8-27B-4bit-mtp", modelType: modelType)), "\(modelType)")
        }
    }

    @Test(arguments: Self.builds, Self.cases)
    func clientReceivesTheRealCallsOnly(build: QwenToolBuild, expected: QwenToolOutputCase) async throws {
        for stream in [true, false] {
            for chunking in stream ? Chunking.allCases : [.whole, .characters] {
                let served = try await Self.serve(build, expected, chunking: chunking, stream: stream)
                let label = "\(stream ? "streamed" : "collected"), \(chunking.rawValue): \(served)"
                #expect(served.error == nil, "\(label)")
                #expect(served.calls.count == expected.calls.count, "\(label)")
                for (call, want) in zip(served.calls, expected.calls) {
                    #expect(call.name == want.0, "\(label)")
                    #expect(Self.sameJSON(call.arguments, want.1), "\(label)")
                }
                #expect(served.content.trimmingCharacters(in: .whitespacesAndNewlines) == expected.content, "\(label)")
                if let reasoning = expected.reasoning {
                    #expect(served.reasoning.trimmingCharacters(in: .whitespacesAndNewlines) == reasoning, "\(label)")
                }
                let finish = expected.calls.isEmpty ? (expected.lengthStop ? "length" : "stop") : "tool_calls"
                #expect(served.finishReason == finish, "\(label)")
                // An `auto` call still streams while it is generated: its name
                // and arguments leave in more than one fragment.
                if stream, expected.choice == .auto, expected.calls.count == 1, chunking != .whole {
                    #expect(served.toolFrames > 1, "\(label)")
                }
            }
        }
    }

    private static func serve(
        _ build: QwenToolBuild, _ expected: QwenToolOutputCase, chunking: Chunking, stream: Bool
    ) async throws -> Served {
        var body: [String: Any] = [
            "model": build.id, "max_tokens": 4096, "stream": stream, "tools": tools,
            "messages": [["role": "user", "content": "What is the weather in Zürich?"]],
        ]
        switch expected.choice {
        case .auto: body["tool_choice"] = "auto"
        case .required: body["tool_choice"] = "required"
        case .named: body["tool_choice"] = ["type": "function", "function": ["name": "get_weather"]]
        case .thinkingOff: body["reasoning"] = ["enabled": false]
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        var request = try ProviderLoop.decodeOpenAIRequest(data, modelType: build.modelType)
        request.reasoningParser = ProviderLoop.inferReasoningParser(for: build.modelType)
        if stream { request.streamOptions = .init(includeUsage: true) }
        let engine = ScriptedQwenEngine(chunks: chunking.split(expected.output),
                                        finish: expected.lengthStop ? .length : .stop)
        let tokenizer = Self.tokenizer
        let bridge = EngineV2Bridge(engine: engine, modelId: build.id, tokenizer: tokenizer,
                                    eosTokenIds: [248046, 248044])
        let id = build.id
        let modelType = build.modelType
        let scheduler = MultiModelBatchSchedulerEngine(
            registryProvider: { [id: .init(tokenizer: tokenizer, modelType: modelType, engineV2Bridge: bridge)] },
            templateControls: ProviderLoop.extractChatTemplateControls(from: data))
        let service = MLXOpenAIService(engine: scheduler)
        var served = Served()
        do {
            if stream {
                for try await frame in try await service.streamChatCompletionFrames(request: request) {
                    Self.record(frame, into: &served)
                }
            } else {
                let response = try await service.createChatCompletion(request: request)
                Self.record(try JSONEncoder().encode(response), into: &served)
            }
        } catch {
            served.error = "\(error)"
        }
        await bridge.shutdown()
        return served
    }

    /// One SSE frame as an OpenAI client reassembles it.
    private static func record(_ frame: String, into served: inout Served) {
        guard frame.hasPrefix("data: {"),
            let chunk = try? JSONSerialization.jsonObject(with: Data(frame.dropFirst(6).utf8)) as? [String: Any],
            let choice = (chunk["choices"] as? [[String: Any]])?.first
        else { return }
        let delta = choice["delta"] as? [String: Any] ?? [:]
        served.reasoning += delta["reasoning_content"] as? String ?? ""
        served.content += delta["content"] as? String ?? ""
        for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
            served.toolFrames += 1
            let function = call["function"] as? [String: Any] ?? [:]
            let fragment = function["arguments"] as? String ?? ""
            if let name = function["name"] as? String {
                served.calls.append(.init(name: name, arguments: fragment))
            } else if !served.calls.isEmpty {
                served.calls[served.calls.count - 1].arguments += fragment
            }
        }
        if let reason = choice["finish_reason"] as? String { served.finishReason = reason }
    }

    /// One collected (non-streamed) response.
    private static func record(_ response: Data, into served: inout Served) {
        guard let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
            let choice = (object["choices"] as? [[String: Any]])?.first,
            let message = choice["message"] as? [String: Any]
        else { served.error = "unreadable response"; return }
        served.content = message["content"] as? String ?? ""
        served.reasoning = message["reasoning_content"] as? String ?? ""
        for call in message["tool_calls"] as? [[String: Any]] ?? [] {
            let function = call["function"] as? [String: Any] ?? [:]
            served.calls.append(.init(name: function["name"] as? String ?? "",
                                      arguments: function["arguments"] as? String ?? ""))
        }
        served.finishReason = choice["finish_reason"] as? String
    }

    private static func sameJSON(_ left: String, _ right: String) -> Bool {
        guard let a = try? JSONSerialization.jsonObject(with: Data(left.utf8)) as? NSDictionary,
            let b = try? JSONSerialization.jsonObject(with: Data(right.utf8)) as? NSDictionary
        else { return false }
        return a == b
    }
}
