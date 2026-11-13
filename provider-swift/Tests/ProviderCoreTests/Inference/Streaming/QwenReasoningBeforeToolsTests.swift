// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// One engine row that says `chunks`, one delta each (the test tokenizer's
/// tokens), then ends with `finish`.
private final class ScriptedQwenEngine: CBv2Engine, Sendable {
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

#if DEBUG
/// The forwarder alone over the same output, with the route chosen by the
/// caller: `nativeReasoningPrefix` nil is the raw-text route, the seed is the
/// native split (`promotes`: with the trailing-call rule, as production runs
/// it). Prompt policy, parser and handler are production's.
private struct RoutedQwenEngine: MLXServerEngine {
    let chunks: [String]
    let modelType: String
    let seed: String
    let native: Bool
    let promotes: Bool
    let finish: String

    func availableModels() async throws -> [MLXServerModel] { [] }

    func streamChatCompletion(
        request: OpenAIChatCompletionRequest
    ) async throws -> AsyncThrowingStream<MLXServerGenerationEvent, Error> {
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: modelType)
        let handler = try ToolStreamPreparation.makeHandler(
            request: request, prepared: prepared, modelType: modelType, streamToolCalls: true)
        let upstream = AsyncStream<GenerationEvent>.makeStream()
        for chunk in chunks where !chunk.isEmpty { upstream.continuation.yield(.chunk(chunk)) }
        upstream.continuation.yield(.info(promptTokens: 9, completionTokens: chunks.count, tokensPerSecond: 0,
            finishReason: finish))
        upstream.continuation.finish()
        return try MultiModelBatchSchedulerEngine(registryProvider: { [:] })._testMakeEventStream(
            upstream: upstream.stream, cancelUpstream: {}, prepared: prepared,
            releaseBox: OneShotRelease(release: { _ in }, modelId: request.model),
            reasoningPrefix: seed, toolHandler: handler, nativeReasoningPrefix: native ? seed : nil,
            promotesTrailingReasoningCalls: native && promotes)
    }

    func tokenize(_ request: TokenizeRequest) async throws -> TokenizeResponse { .init(tokens: []) }
    func detokenize(_ request: DetokenizeRequest) async throws -> DetokenizeResponse { .init(text: "") }
    func applyTemplate(_ request: ApplyTemplateRequest) async throws -> TokenizeResponse { .init(tokens: []) }
}
#endif

/// How generated text reaches the scheduler: whole, one character per delta,
/// three characters per delta, or cut in the middle of every think and tool
/// marker.
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
    struct Call: CustomStringConvertible, Equatable {
        var name: String
        var arguments: String
        var description: String { "\(name)(\(arguments))" }
    }

    var content = ""
    var reasoning = ""
    var calls: [Call] = []
    /// Streamed responses: what each delta frame carried, in order
    /// ("reasoning", "content", "tool").
    var order: [String] = []
    var finishReason: String?
    var completionTokens: Int?
    var error: String?

    var toolFrames: Int { order.filter { $0 == "tool" }.count }

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
    var parallel: Bool?
    /// An explicit `reasoning_parser` (nil: the model type's, as ProviderLoop resolves it).
    var parser: String?
    var lengthStop = false
    /// Expected calls: name and arguments as a JSON object string.
    let calls: [(String, String)]
    /// Expected visible content, ignoring surrounding whitespace.
    var content = ""
    /// Expected reasoning, ignoring surrounding whitespace (nil: not checked).
    var reasoning: String?
    /// The call is generated after `</think>`, so it streams while generated
    /// (false: it is promoted from an unclosed thought at the end of the output).
    var streamsWhileGenerated = true

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

    static let noteCall = "<tool_call>\n<function=save_note>\n<parameter=title>\nTags\n</parameter>\n"
        + "<parameter=body>\nwrite </think> then <think> literally\n</parameter>\n"
        + "<parameter=tags>\n[\"a\", \"b\"]\n</parameter>\n</function>\n</tool_call>"
    static let jsonCall = "<tool_call>\n{\"name\": \"save_note\", \"arguments\": {\"title\": \"T\", "
        + "\"body\": \"a </tool_call> b </think> c <think>\"}}\n</tool_call>"
    /// Inside a thought a literal `</think>` ends it, wherever it is (as on
    /// every native family), so this one spells only the other markers.
    static let jsonCallInThought = "<tool_call>\n{\"name\": \"save_note\", \"arguments\": {\"title\": \"T\", "
        + "\"body\": \"a </tool_call> b <tool_call>\\n<function=x> c <think>\"}}\n</tool_call>"

    /// Outputs with no tool syntax in the thought: both routes must give the
    /// client the same bytes.
    static let clean: [QwenToolOutputCase] = [
        .init(name: "a call after a thought",
              output: "Let me check the weather.\n</think>\n\n" + call("Zürich", unit: "celsius"),
              calls: [weather("Zürich", unit: "celsius")], reasoning: "Let me check the weather."),
        .init(name: "two calls",
              output: "Two cities.\n</think>\n\n" + call("Zürich") + "\n" + call("Paris"),
              calls: [weather("Zürich"), weather("Paris")]),
        .init(name: "a text answer", output: "Simple.\n</think>\n\nZürich is cool in November.",
              calls: [], content: "Zürich is cool in November.", reasoning: "Simple."),
        .init(name: "an answer that mentions the tag",
              output: "Simple.\n</think>\n\nTo call a tool, write <tool_call> followed by the function block.",
              calls: [], content: "To call a tool, write <tool_call> followed by the function block."),
        .init(name: "a thought that never closes",
              output: "I keep thinking about this and never close the block", lengthStop: true,
              calls: [], reasoning: "I keep thinking about this and never close the block"),
        .init(name: "XML arguments that spell think markers stay arguments",
              output: "Saving it.\n</think>\n\n" + noteCall,
              calls: [("save_note", #"{"title":"Tags","body":"write </think> then <think> literally","tags":["a","b"]}"#)]),
        .init(name: "a JSON-dialect call whose strings spell the markers",
              output: "Saving it.\n</think>\n\n" + jsonCall,
              calls: [("save_note", #"{"title":"T","body":"a </tool_call> b </think> c <think>"}"#)]),
        .init(name: "a second thought after an answer",
              output: "First.\n</think>\n\nZürich is cool.<think>\nSecond.\n</think>\n\nReally.",
              calls: [], content: "Zürich is cool.\n\nReally."),
        .init(name: "thinking off: a call", output: call("Bern"), choice: .thinkingOff, calls: [weather("Bern")]),
        .init(name: "thinking off: a text answer", output: "Zürich is cool in November.", choice: .thinkingOff,
              calls: [], content: "Zürich is cool in November."),
        .init(name: "thinking off: a stray </think> stays text", output: "hmm\n</think>\n\nAnswer: B",
              choice: .thinkingOff, calls: [], content: "hmm\n</think>\n\nAnswer: B"),
        .init(name: "required: a call", output: call("Bern"), choice: .required, calls: [weather("Bern")]),
        .init(name: "named: a call", output: call("Bern"), choice: .named, calls: [weather("Bern")]),
    ]

    /// Tool syntax in the thought that the raw route already got right: the split keeps it right.
    static let unchanged: [QwenToolOutputCase] = [
        .init(name: "only <function=…> mentioned, then the call",
              output: "Use the <function=get_weather> block.\n</think>\n\n" + call("Bern"), calls: [weather("Bern")]),
        .init(name: "only </tool_call> mentioned, then the call",
              output: "End with </tool_call> after the call.\n</think>\n\n" + call("Bern"), calls: [weather("Bern")]),
        .init(name: "both tags mentioned, then the call",
              output: "Format: <tool_call> ... </tool_call>.\n</think>\n\n" + call("Bern"), calls: [weather("Bern")]),
        .init(name: "a text answer after a thought that mentions the tag",
              output: "The <tool_call> syntax is not needed.\n</think>\n\nZürich is cool.",
              calls: [], content: "Zürich is cool.", reasoning: "The <tool_call> syntax is not needed."),
        // A thought that never closes and ends in complete frames is the model
        // calling from inside it (vLLM #35687): those calls still parse.
        .init(name: "a call written in a thought that never closes, then the end of the turn",
              output: "I need the weather.\n" + call("Bern"), calls: [weather("Bern")],
              streamsWhileGenerated: false),
        .init(name: "two calls written back to back in a thought that never closes, then the end of the turn",
              output: "Two cities.\n" + call("Zürich") + call("Paris"),
              calls: [weather("Zürich"), weather("Paris")], streamsWhileGenerated: false),
        .init(name: "a JSON-dialect call written in a thought that never closes, then the end of the turn",
              output: "Saving it.\n" + jsonCallInThought,
              calls: [("save_note", #"{"title":"T","body":"a </tool_call> b <tool_call>\n<function=x> c <think>"}"#)],
              streamsWhileGenerated: false),
        .init(name: "thinking off: a stray thought that never closes and ends in a call",
              output: "<think>\nI need the weather.\n" + call("Bern"), choice: .thinkingOff,
              calls: [weather("Bern")], streamsWhileGenerated: false),
        .init(name: "a lone tag mentioned in a thought that never closes",
              output: "Wrap it in <tool_call> tags", calls: [], reasoning: "Wrap it in <tool_call> tags"),
        // Gating: an explicit non-think parser keeps the raw route (no split at all).
        .init(name: "reasoning_parser none keeps the raw output",
              output: "Let me check the weather.\n</think>\n\n" + call("Bern"), parser: "none",
              calls: [weather("Bern")], content: "Let me check the weather.\n</think>", reasoning: ""),
    ]

    /// Where the split differs from the raw route, each failing without it: what the raw route got wrong
    /// (CONFORMANCE's replay cases, `replay/out/qwen38*`, and the shapes around them) and, last, the trade-off it
    /// documents for calls in a thought that never closes.
    static let fixed: [QwenToolOutputCase] = [
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
        .init(name: "two calls after a lone mentioned tag",
              output: "Two cities, each in its own <tool_call> block.\n</think>\n\n" + call("Zürich") + "\n"
                  + call("Paris"),
              calls: [weather("Zürich"), weather("Paris")]),
        .init(name: "a call drafted in the thought, then the real call",
              output: "I'll call " + call("Paris") + " to get it.\n</think>\n\n" + call("Zürich"),
              calls: [weather("Zürich")], reasoning: "I'll call " + call("Paris") + " to get it."),
        .init(name: "parallel_tool_calls false: a call drafted in the thought, then the real call",
              output: "I'll call " + call("Paris") + " to get it.\n</think>\n\n" + call("Zürich"), parallel: false,
              calls: [weather("Zürich")]),
        .init(name: "a call written only in the thought, then a text answer",
              output: "I'll call " + call("Paris") + " later.\n</think>\n\nI can't check the weather right now.",
              calls: [], content: "I can't check the weather right now.",
              reasoning: "I'll call " + call("Paris") + " later."),
        .init(name: "a call written in a thought that closes, with nothing after it",
              output: "I need the weather.\n" + call("Bern") + "\n</think>\n\n", calls: [],
              reasoning: "I need the weather.\n" + call("Bern")),
        .init(name: "a call drafted in a thought that never closes, then more thought",
              output: "Maybe " + call("Paris") + "\nNo, Bern is closer.", calls: [],
              reasoning: "Maybe " + call("Paris") + "\nNo, Bern is closer."),
        .init(name: "a call drafted in a thought cut off by the token limit",
              output: "Maybe " + call("Paris") + " but I am still thinking", lengthStop: true,
              calls: [], reasoning: "Maybe " + call("Paris") + " but I am still thinking"),
        .init(name: "a call at the end of a thought cut off by the token limit",
              output: "I need the weather.\n" + call("Bern"), lengthStop: true,
              calls: [], reasoning: "I need the weather.\n" + call("Bern")),
        .init(name: "thinking off: a call at the end of a stray thought cut off by the token limit",
              output: "<think>\nI need the weather.\n" + call("Bern"), choice: .thinkingOff, lengthStop: true,
              calls: [], reasoning: "I need the weather.\n" + call("Bern")),
        .init(name: "a mention that opens like a call, then a call, in a thought that never closes",
              output: "I'll emit <tool_call>\n<function=get_weather> for Bern.\n" + call("Bern"),
              calls: [weather("Bern")], streamsWhileGenerated: false),
        .init(name: "thinking off: a stray thought that mentions the tag, then the call",
              output: "<think>\nWrap it in <tool_call> tags.\n</think>\n\n" + call("Bern"), choice: .thinkingOff,
              calls: [weather("Bern")], reasoning: "Wrap it in <tool_call> tags."),
        .init(name: "required: a stray thought that mentions the tag, then the call",
              output: "<think>\nWrap it in <tool_call> tags.\n</think>\n\n" + call("Bern"), choice: .required,
              calls: [weather("Bern")], reasoning: "Wrap it in <tool_call> tags."),
        .init(name: "required: a stray thought that never closes and ends in the call",
              output: "<think>\nI need the weather.\n" + call("Bern"), choice: .required,
              calls: [weather("Bern")], streamsWhileGenerated: false),
        // The raw route ran both calls too, but sent the newline between them as reasoning after the first call.
        .init(name: "two calls on their own lines at the end of a thought that never closes: no reasoning between them",
              output: "Two cities.\n" + call("Zürich") + "\n" + call("Paris") + "\n",
              calls: [weather("Zürich"), weather("Paris")], streamsWhileGenerated: false),
        // The trade-off: only the frames at the very end of the thought are calls. A draft and a second real call
        // cannot be told apart, so a call separated from them by text stays reasoning (the raw route ran both).
        .init(name: "two calls with text between them in a thought that never closes: the last one",
              output: "I need both.\n" + call("Zürich") + "\nAnd Paris too:\n" + call("Paris"),
              calls: [weather("Paris")], streamsWhileGenerated: false),
    ]

    static let cases = clean + unchanged + fixed
    static let callsFromUnclosedThoughts = unchanged.filter { !$0.streamsWhileGenerated }

    /// The route is the Qwen 3.5 types' alone: native families keep their own, other Qwen types the raw one,
    /// and `auto` calls keep streaming (their deltas key on the native-channel predicate, which stays false).
    @Test func routingIsScopedToTheQwen35Types() {
        for build in Self.builds {
            let context = ChatTemplateFixContext(modelId: build.id, modelType: build.modelType)
            #expect(ToolChoiceEnforcementPolicy.splitsQwenReasoningBeforeTools(context))
            #expect(!ToolChoiceEnforcementPolicy.usesNativeTextChannels(context))
        }
        for modelType in ["Qwen3_5", " qwen3_5_moe\n"] {
            #expect(ToolChoiceEnforcementPolicy.splitsQwenReasoningBeforeTools(
                .init(modelId: "EigenLabs/Qwen3.8-27B-4bit-mtp", modelType: modelType)), "\(modelType)")
        }
        for modelType in ["qwen3_next", "qwen3_vl_moe", "qwen3", "prism_hadamard_qwen35", "qwen4_exp", "gemma4",
                          "glm5_next", "gpt_oss", "mimo_v2", "nemotron_h", "llama"] {
            #expect(!ToolChoiceEnforcementPolicy.splitsQwenReasoningBeforeTools(
                .init(modelId: "EigenLabs/Qwen3.8-27B-4bit-mtp", modelType: modelType)), "\(modelType)")
        }
    }

    /// Only complete frames that parse and end an open thought, whitespace aside, are promoted: never a mentioned
    /// tag (even one that opens like a call), a frame with more thought after it, a tag inside an argument, or an
    /// unfinished frame.
    @Test func trailingCallsAreCompleteFramesAtTheEndOfTheThought() {
        let paris = Self.call("Paris"), bern = Self.call("Bern")
        let nested = "<tool_call>\n<function=save_note>\n<parameter=body>\nsee <tool_call>\n<function=x>\n</parameter>\n"
            + "</function>\n</tool_call>"
        // A mention that reaches its first `<parameter=` cannot be told from a call whose argument spells the tags
        // (`nested`): the frame runs on to the real call's end and parses, as on the raw route.
        let opensAParameter = "<tool_call>\n<function=get_weather>\n<parameter=location> with the city.\n" + bern
        // The JSON dialect with the redundant outer braces that `JSONToolCallParser` also accepts.
        let braces = "<tool_call>\n{{\"name\": \"get_weather\", \"arguments\": {\"location\": \"Bern\"}}}}\n</tool_call>"
        for (thought, trailing) in [
            ("I need the weather.\n" + bern, bern),
            ("I need the weather.\n" + bern + "\n \n", bern + "\n \n"),
            ("Two.\n" + paris + "\n" + bern, paris + "\n" + bern),
            ("Maybe " + paris + " no.\n" + bern, bern),
            ("Both.\n" + paris + "\nAnd Bern:\n" + bern, bern),
            ("Use <tool_call> tags.\n" + bern, bern),
            ("I'll emit <tool_call>\n<function=get_weather> for Bern.\n" + bern, bern),
            ("Emit <tool_call>{name, arguments}.\n" + bern, bern),
            ("Saving.\n" + nested, nested),
            ("Saving.\n" + Self.jsonCallInThought, Self.jsonCallInThought),
            ("I'll write " + opensAParameter, opensAParameter),
            ("Calling.\n" + braces, braces),
            // Thousands of mentions that open like calls cost nothing: each is read as a mention at its prose.
            (String(repeating: "Emit <tool_call>\n<function=get_weather> for X. ", count: 3_000) + bern, bern),
        ] {
            #expect(NativeChannelSplitter.trailingCalls(in: thought) == trailing, "\(thought.prefix(200))")
        }
        for thought in ["Maybe " + paris + " no.", "Use <tool_call> tags", "Use <tool_call> tags </tool_call>",
                        "Broken <tool_call>\n<function=get_weather>\nnot a parameter\n</tool_call>",
                        "Half " + String(bern.dropLast(3)), "", "No calls at all."] {
            #expect(NativeChannelSplitter.trailingCalls(in: thought) == nil, "\(thought)")
        }
        // With the request's tools, a frame with an undeclared name (an echoed template example) is a mention.
        let example = "<tool_call>\n<function=example_function_name>\n<parameter=example_parameter_1>\nvalue_1\n"
            + "</parameter>\n</function>\n</tool_call>"
        let declared: [[String: any Sendable]] = [
            ["type": "function", "function": ["name": "get_weather"] as [String: any Sendable]],
        ]
        #expect(NativeChannelSplitter.trailingCalls(in: "Like this:\n" + example + "\n" + bern, tools: declared) == bern)
        #expect(NativeChannelSplitter.trailingCalls(in: "Like this:\n" + example + "\n" + bern) == example + "\n" + bern)
        // Thousands of frames that read as calls up to their first parameter and then fail to parse, each running
        // on to the last frame's end: the work stays bounded, and past the bound nothing is promoted.
        let degenerate = String(repeating: "<tool_call>\n<function=get_weather>\n<parameter=location>\nX\n</parameter>\n"
            + "again ", count: 2_000) + bern
        #expect(NativeChannelSplitter.trailingCalls(in: degenerate) == nil)
        // At any chunking, the frames that end an open thought also leave as content at the end of the output, and
        // only then; a closed thought, a cut at the token limit or the option off leaves them reasoning.
        for width in [1, 3, 1_000] {
            func split(_ text: String, promotes: Bool, cut: Bool) -> (reasoning: String, content: String) {
                var splitter = NativeChannelSplitter(prefix: "<think>", protectToolFrames: true,
                    qwenStructuredFrames: true, promotesTrailingCalls: promotes)
                let characters = Array(text)
                var pieces: [ParsedReasoning] = []
                for start in stride(from: 0, to: characters.count, by: width) {
                    pieces += splitter.parse(String(characters[start..<min(start + width, characters.count)]))
                }
                if cut { splitter.outputReachedTokenLimit() }
                pieces += splitter.finish()
                return (pieces.compactMap(\.reasoningContent).joined(), pieces.map(\.content).joined())
            }
            for (text, promotes, cut, reasoning, content) in [
                ("Need it.\n" + bern, true, false, "Need it.\n" + bern, bern),
                ("Need it.\n" + bern, false, false, "Need it.\n" + bern, ""),
                ("Need it.\n" + bern, true, true, "Need it.\n" + bern, ""),
                ("Need it.\n" + bern + "</think>", true, false, "Need it.\n" + bern, ""),
                ("Plan.</think>\n\n<think>Need it.\n" + bern, true, false, "Plan.Need it.\n" + bern, "\n\n" + bern),
            ] {
                let result = split(text, promotes: promotes, cut: cut)
                #expect(result.reasoning == reasoning && result.content == content, "\(width): \(text)")
            }
        }
    }

    @Test(arguments: Self.builds, Self.cases)
    func clientReceivesTheRealCallsOnly(build: QwenToolBuild, expected: QwenToolOutputCase) async throws {
        for stream in [true, false] {
            for chunking in stream ? Chunking.allCases : [.whole, .characters] {
                let chunks = chunking.split(expected.output)
                let served = try await Self.serve(build, expected, chunks: chunks, stream: stream)
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
                // Every generated token is billed, whichever channel it lands in.
                let tokens = chunks.reduce(0) { $0 + QwenByteTestTokenizer.tokens($1).count }
                #expect(served.completionTokens == tokens, "\(label)")
                guard stream, !expected.calls.isEmpty else { continue }
                // Reasoning leaves before the calls, and calls before the finish frame.
                let firstTool = served.order.firstIndex(of: "tool") ?? served.order.count
                #expect(!served.order[firstTool...].contains("reasoning"), "\(label)")
                // An `auto` call still streams while it is generated: its name
                // and arguments leave in more than one fragment.
                if expected.choice == .auto, expected.calls.count == 1, expected.streamsWhileGenerated,
                    chunking != .whole {
                    #expect(served.toolFrames > 1, "\(label)")
                }
            }
        }
    }

    #if DEBUG
    /// Where the thought holds no tool syntax, the native split and the raw
    /// route give the client the same bytes: content, reasoning, calls and
    /// the finish reason, untrimmed, at every chunking.
    @Test(arguments: Self.clean)
    func cleanOutputIsTheSameOnBothRoutes(expected: QwenToolOutputCase) async throws {
        for chunking in Chunking.allCases {
            let chunks = chunking.split(expected.output)
            let raw = try await Self.route(expected, chunks: chunks, native: false)
            let native = try await Self.route(expected, chunks: chunks, native: true)
            #expect(raw.error == nil && native.error == nil, "\(chunking.rawValue): \(raw) | \(native)")
            #expect(native.content == raw.content, "\(chunking.rawValue): \(raw) | \(native)")
            #expect(native.reasoning == raw.reasoning, "\(chunking.rawValue): \(raw) | \(native)")
            #expect(native.calls == raw.calls, "\(chunking.rawValue): \(raw) | \(native)")
            #expect(native.finishReason == raw.finishReason, "\(chunking.rawValue): \(raw) | \(native)")
        }
    }

    /// Calls at the end of a thought that never closes: the split returns the
    /// raw route's calls, content and finish reason, once the output ends, and
    /// the whole thought, calls included, stays its reasoning.
    @Test(arguments: Self.callsFromUnclosedThoughts)
    func callsFromAnUnclosedThoughtMatchTheRawRoute(expected: QwenToolOutputCase) async throws {
        let thought = expected.output.hasPrefix("<think>")
            ? String(expected.output.dropFirst("<think>".count)) : expected.output
        for chunking in Chunking.allCases {
            let chunks = chunking.split(expected.output)
            let raw = try await Self.route(expected, chunks: chunks, native: false)
            let native = try await Self.route(expected, chunks: chunks, native: true, promotes: true)
            let label = "\(chunking.rawValue): \(raw) | \(native)"
            #expect(raw.error == nil && native.error == nil, "\(label)")
            #expect(raw.calls.count == expected.calls.count && native.calls.count == raw.calls.count, "\(label)")
            for (call, want) in zip(native.calls, raw.calls) {
                #expect(call.name == want.name && Self.sameJSON(call.arguments, want.arguments), "\(label)")
            }
            #expect(native.content.trimmingCharacters(in: .whitespacesAndNewlines)
                == raw.content.trimmingCharacters(in: .whitespacesAndNewlines), "\(label)")
            #expect(native.finishReason == raw.finishReason, "\(label)")
            #expect(native.reasoning == thought, "\(label)")
        }
    }
    #endif

    private static func body(_ build: QwenToolBuild, _ expected: QwenToolOutputCase, stream: Bool) -> [String: Any] {
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
        if let parallel = expected.parallel { body["parallel_tool_calls"] = parallel }
        if let parser = expected.parser { body["reasoning_parser"] = parser }
        return body
    }

    /// The coordinator relay's path (a forced stream) or the local API's
    /// collected response, over a slot whose engine row says `chunks`.
    private static func serve(
        _ build: QwenToolBuild, _ expected: QwenToolOutputCase, chunks: [String], stream: Bool
    ) async throws -> Served {
        let data = try JSONSerialization.data(withJSONObject: body(build, expected, stream: stream))
        var request = try ProviderLoop.decodeOpenAIRequest(data, modelType: build.modelType)
        if request.reasoningParser == nil {
            request.reasoningParser = ProviderLoop.inferReasoningParser(for: build.modelType)
        }
        if stream { request.streamOptions = .init(includeUsage: true) }
        let engine = ScriptedQwenEngine(chunks: chunks, finish: expected.lengthStop ? .length : .stop)
        let tokenizer = Self.tokenizer
        let bridge = EngineV2Bridge(engine: engine, modelId: build.id, tokenizer: tokenizer,
                                    eosTokenIds: [248046, 248044])
        let id = build.id
        let modelType = build.modelType
        let scheduler = MultiModelBatchSchedulerEngine(
            registryProvider: { [id: .init(tokenizer: tokenizer, modelType: modelType, engineV2Bridge: bridge)] },
            templateControls: ProviderLoop.extractChatTemplateControls(from: data))
        let served = try await collect(MLXOpenAIService(engine: scheduler), request, stream: stream)
        await bridge.shutdown()
        return served
    }

    #if DEBUG
    /// The forwarder alone, on the raw route or the native split, streamed.
    private static func route(
        _ expected: QwenToolOutputCase, chunks: [String], native: Bool, promotes: Bool = false
    ) async throws -> Served {
        let build = builds[0]
        let data = try JSONSerialization.data(withJSONObject: body(build, expected, stream: true))
        var request = try ProviderLoop.decodeOpenAIRequest(data, modelType: build.modelType)
        request.reasoningParser = .qwen3
        request.streamOptions = .init(includeUsage: true)
        let seed = expected.choice == .auto ? "<think>" : "<think></think>"
        let engine = RoutedQwenEngine(chunks: chunks, modelType: build.modelType, seed: seed, native: native,
                                      promotes: promotes, finish: expected.lengthStop ? "length" : "stop")
        return try await collect(MLXOpenAIService(engine: engine), request, stream: true)
    }
    #endif

    private static func collect(
        _ service: MLXOpenAIService, _ request: OpenAIChatCompletionRequest, stream: Bool
    ) async throws -> Served {
        var served = Served()
        do {
            if stream {
                for try await frame in try await service.streamChatCompletionFrames(request: request) {
                    record(frame, into: &served)
                }
            } else {
                let response = try await service.createChatCompletion(request: request)
                record(try JSONEncoder().encode(response), into: &served)
            }
        } catch {
            served.error = "\(error)"
        }
        return served
    }

    /// One SSE frame as an OpenAI client reassembles it.
    private static func record(_ frame: String, into served: inout Served) {
        guard frame.hasPrefix("data: {"),
            let chunk = try? JSONSerialization.jsonObject(with: Data(frame.dropFirst(6).utf8)) as? [String: Any]
        else { return }
        if let usage = chunk["usage"] as? [String: Any] { served.completionTokens = usage["completion_tokens"] as? Int }
        guard let choice = (chunk["choices"] as? [[String: Any]])?.first else { return }
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
            served.order.append("tool")
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
        served.completionTokens = (object["usage"] as? [String: Any])?["completion_tokens"] as? Int
    }

    private static func sameJSON(_ left: String, _ right: String) -> Bool {
        guard let a = try? JSONSerialization.jsonObject(with: Data(left.utf8)) as? NSDictionary,
            let b = try? JSONSerialization.jsonObject(with: Data(right.utf8)) as? NSDictionary
        else { return false }
        return a == b
    }
}
