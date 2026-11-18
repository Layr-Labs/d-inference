import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// MiMo V2.6, Nemotron 3.5 Lightning and Bonsai 2, the served native-channel
/// families on the scheduler's text path: their tool calls must reach a client that
/// streams while they are generated, as Gemma's and Qwen's do, under the
/// same rules (`StreamedToolCallTests`).
@Suite("Streamed native tool calls")
struct NativeStreamedToolCallTests {
    /// One served family: its serving identity, its native channel set-up as
    /// the scheduler's text path makes it, and its call frame.
    struct Family: CustomTestStringConvertible, Sendable {
        let model: String
        let modelType: String
        /// `nativeReasoningPrefix` as the text path seeds it.
        let nativePrefix: String
        let nativeMiMoChannels: Bool
        let absorbStrayThinkClose: Bool
        var preserveInnerReasoningSpans = false
        /// `<tool_call>` frame of one call; values are written as the
        /// family's template writes them.
        let frame: @Sendable (_ name: String, _ parameters: [(String, String)]) -> String

        var testDescription: String { modelType }

        static let mimo = Family(model: "mimo-v2.6-flash-mopd", modelType: "mimo_v2", nativePrefix: "",
            nativeMiMoChannels: true, absorbStrayThinkClose: false) { name, parameters in
                "<tool_call><function=\(name)>"
                    + parameters.map { "<parameter=\($0.0)>\($0.1)</parameter>" }.joined()
                    + "</function></tool_call>"
            }
        static let lightning = Family(model: "nvidia-nemotron-3.5-lightning", modelType: "nemotron_h",
            nativePrefix: "<think></think>", nativeMiMoChannels: false, absorbStrayThinkClose: true) { name, parameters in
                "<tool_call>\n<function=\(name)>\n"
                    + parameters.map { "<parameter=\($0.0)>\n\($0.1)\n</parameter>\n" }.joined()
                    + "</function>\n</tool_call>"
            }
        static let bonsai = Family(model: "ternary-bonsai-2-27b", modelType: "prism_hadamard_qwen35",
            nativePrefix: "<think></think>", nativeMiMoChannels: false, absorbStrayThinkClose: false,
            preserveInnerReasoningSpans: true, frame: lightning.frame)
        static let all = [mimo, lightning, bonsai]
        static let bonsai9B = Family(model: Bonsai9BModelPolicy.modelID, modelType: "prism_hadamard_qwen35",
            nativePrefix: "<think></think>", nativeMiMoChannels: false, absorbStrayThinkClose: false,
            preserveInnerReasoningSpans: true, frame: lightning.frame)

        /// Lightning with thinking on: the prompt leaves the thought open.
        var thinking: Family {
            Family(model: model, modelType: modelType, nativePrefix: modelType == "mimo_v2" ? "" : "<think>",
                nativeMiMoChannels: nativeMiMoChannels, absorbStrayThinkClose: absorbStrayThinkClose,
                preserveInnerReasoningSpans: preserveInnerReasoningSpans, frame: frame)
        }
    }

    private static let tools = """
        [{"type":"function","function":{"name":"get_weather","parameters":{"type":"object",
          "properties":{"location":{"type":"string"},"days":{"type":"integer"}},"required":["location"]}}},
         {"type":"function","function":{"name":"write_file","parameters":{"type":"object",
          "properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}}}]
        """

    static func request(_ family: Family, _ choice: OpenAIToolChoice? = nil, parallel: Bool? = nil,
                        clientStreams: Bool = true) throws -> OpenAIChatCompletionRequest {
        var request = OpenAIChatCompletionRequest(
            model: family.model,
            messages: [.init(role: .user, content: .text("Write the file."))],
            tools: try JSONDecoder().decode([OpenAITool].self, from: Data(tools.utf8)),
            toolChoice: choice, parallelToolCalls: parallel, stream: clientStreams,
            streamOptions: clientStreams ? .init(includeUsage: true) : nil)
        request.streamToolCallDeltas = false // set by the service itself
        return request
    }

    private static func characters(_ text: String) -> [String] { text.map(String.init) }

    private static func streamedCall(_ chunks: [ProviderLoop.StreamChunkExtract]) -> (name: String?, arguments: String) {
        let deltas = chunks.flatMap { $0.toolCallsDelta ?? [] }
        return (deltas.compactMap { $0.function?.name }.first,
                deltas.compactMap { $0.function?.arguments }.joined())
    }

    private static func decoded(_ arguments: String) throws -> [String: MLXLMCommon.JSONValue] {
        try JSONDecoder().decode([String: MLXLMCommon.JSONValue].self, from: Data(arguments.utf8))
    }

    /// A long tool answer from either family held back every byte until
    /// generation ended, so the coordinator's first-content deadline cut it
    /// off. Its name must reach the wire while the arguments are still being
    /// generated, and the call a client rebuilds from the fragments is the
    /// one the complete-call path returned.
    @Test(arguments: Family.all, [OpenAIToolChoice.mode(.auto), .mode(.required), .function(name: "write_file")])
    func longNativeToolAnswersReachTheWireBeforeTheirFrameCloses(family: Family, choice: OpenAIToolChoice)
        async throws
    {
        let upstream = AsyncStream<GenerationEvent>.makeStream()
        let service = MLXOpenAIService(engine: NativeRoutedEngine(upstream: upstream.stream, family: family))
        let log = NativeFrameLog()
        let frames = try await service.streamChatCompletionFrames(request: try Self.request(family, choice))
        let reader = Task {
            for try await frame in frames { await log.append(frame) }
        }
        let content = String(repeating: "print('long answer')\n", count: 40)
        let text = family.frame("write_file", [("path", "long.py"), ("content", content)])
        let head = Self.characters(String(text.prefix(text.count - content.count - 40)))
        for chunk in head { upstream.continuation.yield(.chunk(chunk)) }
        // Most of the answer has not been generated yet.
        #expect(await log.waitForToolFrame(), "the call's first content must leave before its frame closes")
        for chunk in Self.characters(text).dropFirst(head.count) { upstream.continuation.yield(.chunk(chunk)) }
        upstream.continuation.yield(.info(promptTokens: 40, completionTokens: 300, tokensPerSecond: 0,
            finishReason: nil))
        upstream.continuation.finish()
        try await reader.value

        let parsed = await log.frames.compactMap(ProviderLoop.parseStreamChunk)
        let call = Self.streamedCall(parsed)
        #expect(call.name == "write_file")
        #expect(try Self.decoded(call.arguments) == ["path": .string("long.py"), "content": .string(content)])
        #expect(parsed.contains { $0.finishReason == "tool_calls" })
        #expect(!parsed.contains { $0.contentDelta?.isEmpty == false }, "the answer is the call alone")
    }

    // MARK: - Rules

    struct Served {
        let chunks: [ProviderLoop.StreamChunkExtract]
        let error: Error?

        var toolDeltas: [OpenAIToolCallDelta] { chunks.flatMap { $0.toolCallsDelta ?? [] } }
        /// Calls a client rebuilds, by index.
        var calls: [(name: String?, arguments: String)] {
            var calls: [Int: (name: String?, arguments: String)] = [:]
            for delta in toolDeltas {
                let index = delta.index ?? 0
                var call = calls[index] ?? (nil, "")
                if call.name == nil { call.name = delta.function?.name }
                call.arguments += delta.function?.arguments ?? ""
                calls[index] = call
            }
            return calls.keys.sorted().map { calls[$0]! }
        }
        var content: String { chunks.compactMap(\.contentDelta).joined() }
        var reasoning: String { chunks.compactMap(\.reasoningDelta).joined() }
        var finishReason: String? { chunks.compactMap(\.finishReason).last }
        var check: ToolNoncomplianceCheck? { error.flatMap(classifyToolNoncomplianceCheck) }
    }

    /// One response through the service, `chunk` characters per engine chunk.
    static func serve(
        _ family: Family, _ text: String, choice: OpenAIToolChoice? = nil, parallel: Bool? = nil,
        clientStreams: Bool = true, finishReason: String? = nil, streamNative: Bool = true, chunk: Int = 1,
        mimoThinking: Bool = true, withholdReasoning: Bool = false
    ) async throws -> Served {
        let request = try Self.request(family, choice, parallel: parallel, clientStreams: clientStreams)
        let upstream = AsyncStream<GenerationEvent>.makeStream()
        let characters = Self.characters(text)
        for start in stride(from: 0, to: characters.count, by: chunk) {
            upstream.continuation.yield(.chunk(characters[start..<min(start + chunk, characters.count)].joined()))
        }
        upstream.continuation.yield(.info(promptTokens: 9, completionTokens: 30, tokensPerSecond: 0,
            finishReason: finishReason))
        upstream.continuation.finish()
        var frames: [String] = []
        do {
            for try await frame in try await MLXOpenAIService(
                engine: NativeRoutedEngine(upstream: upstream.stream, family: family, streamNative: streamNative,
                    mimoThinking: mimoThinking, withholdReasoning: withholdReasoning)
            ).streamChatCompletionFrames(request: request) {
                frames.append(frame)
            }
        } catch {
            return Served(chunks: frames.compactMap(ProviderLoop.parseStreamChunk), error: error)
        }
        return Served(chunks: frames.compactMap(ProviderLoop.parseStreamChunk), error: nil)
    }

    /// A client that does not stream gets the complete-call output for every
    /// choice: one delta carrying the whole call, as before. The call itself
    /// is the one a streaming client rebuilds from its fragments.
    @Test(arguments: Family.all, [OpenAIToolChoice.mode(.auto), .mode(.required), .function(name: "get_weather")])
    func clientsThatDoNotStreamKeepTheCompleteCallOutput(family: Family, choice: OpenAIToolChoice) async throws {
        let text = family.frame("get_weather", [("location", "Paris"), ("days", "3")])
        let whole = try await Self.serve(family, text, choice: choice, clientStreams: false)
        let streamed = try await Self.serve(family, text, choice: choice)
        #expect(whole.error == nil && streamed.error == nil, "\(String(describing: whole.error ?? streamed.error))")
        #expect(whole.toolDeltas.count == 1)
        #expect(streamed.toolDeltas.count > 1)
        for served in [whole, streamed] {
            #expect(served.calls.count == 1)
            #expect(served.calls.first?.name == "get_weather")
            #expect(try Self.decoded(served.calls.first?.arguments ?? "")
                == ["location": .string("Paris"), "days": .int(3)])
            #expect(served.finishReason == "tool_calls")
        }
    }

    /// `DARKBLOOM_TTFT_STREAM_NATIVE_TOOL_CALLS` off restores the hold-back:
    /// the whole call at the engine terminal, even to a client that streams.
    @Test(arguments: Family.all)
    func theKillSwitchRestoresTheHoldBack(family: Family) async throws {
        let text = family.frame("get_weather", [("location", "Paris")])
        for choice in [OpenAIToolChoice.mode(.auto), .mode(.required)] {
            let off = try await Self.serve(family, text, choice: choice, streamNative: false)
            #expect(off.error == nil)
            #expect(off.toolDeltas.count == 1 && off.calls.first?.name == "get_weather")
            #expect(off.finishReason == "tool_calls")
        }
        let key = ToolStreamPreparation.streamNativeToolCallsEnvironmentKey
        #expect(key == "DARKBLOOM_TTFT_STREAM_NATIVE_TOOL_CALLS")
        for word in ["0", "off", "false", "no", " OFF "] {
            #expect(!ToolStreamPreparation.streamsNativeToolCalls(environment: [key: word]))
        }
        #expect(ToolStreamPreparation.streamsNativeToolCalls(environment: [:]))
        #expect(ToolStreamPreparation.streamsNativeToolCalls(environment: [key: "1"]))
        #expect(LaunchAgent.inferencePassthroughEnvKeys.contains(key))
        // Outside the SSD checkpoint-identity fold (`DARKBLOOM_MIMO_`, `DARKBLOOM_NEMOTRON35_`, ...).
        #expect(!key.hasPrefix("DARKBLOOM_MIMO_") && !key.hasPrefix("DARKBLOOM_NEMOTRON35_"))
    }

    /// Only these families' builds stream (Bonsai's 9B and 27B ids); a
    /// non-chat surface, `none`, another Nemotron build whose parser now
    /// streams, Super on the scheduler (it streams through its own owner),
    /// and the unserved native families keep complete calls here. (GLM's
    /// calls stream through its own `GLM5ToolCallStream`.)
    @Test func onlyTheServedNativeBuildsStream() throws {
        func streams(_ family: Family, _ choice: OpenAIToolChoice? = nil, model: String? = nil,
                     deltas: Bool = true, forced: ToolStreamPreparation.ForcedCalls = .all) throws -> Bool {
            var request = try Self.request(family, choice)
            if let model { request.model = model }
            request.streamToolCallDeltas = deltas
            let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: family.modelType)
            return try ToolStreamPreparation.makeHandler(request: request, prepared: prepared,
                modelType: family.modelType, streamToolCalls: true, streamForcedToolCalls: forced)?.streamsCalls == true
        }
        for family in Family.all + [.bonsai9B] {
            #expect(try streams(family))
            #expect(try streams(family, .mode(.required)))
            #expect(try !streams(family, deltas: false))
            #expect(try !streams(family, .mode(.none)))
            // The forced master switch withholds their forced calls, as every
            // family's; their `auto` calls follow the native switch alone.
            #expect(try !streams(family, .mode(.required), forced: .none))
            #expect(try !streams(family, .function(name: "get_weather"), forced: .none))
            #expect(try streams(family, forced: .none))
            #expect(try streams(family, .mode(.required), forced: .init(qwen: false, gptOSS: false)))
        }
        let master = ToolStreamPreparation.streamForcedToolCallsEnvironmentKey
        #expect(!ToolStreamPreparation.ForcedCalls(environment: [master: "off"]).native)
        #expect(ToolStreamPreparation.ForcedCalls(environment: [
            ToolStreamPreparation.streamForcedQwenToolCallsEnvironmentKey: "off"]).native)
        #expect(try !streams(.lightning, model: "some-other-nemotron"))
        let unchanged = [("flint", "flint"), ("qwen4-exp", "qwen4_exp"), ("diffusion-gemma", "diffusion_gemma"),
            (NemotronSuperLocalBinding.modelID, "nemotron_h_omni")]
        for (model, modelType) in unchanged {
            let family = Family(model: model, modelType: modelType, nativePrefix: "", nativeMiMoChannels: false,
                absorbStrayThinkClose: false, frame: Family.lightning.frame)
            #expect(try !streams(family), "\(modelType)")
            // Some refuse a forced choice outright; none streams one.
            #expect((try? streams(family, .mode(.required))) != true, "\(modelType)")
        }
    }

    /// Engine chunks of several characters, as real decoders emit them,
    /// rebuild the same calls and text as one character at a time and as the
    /// complete-call path.
    @Test(arguments: Family.all, [3, 7, 64])
    func multiCharacterChunksRebuildTheSameAnswer(family: Family, chunk: Int) async throws {
        let text = "Checking.\n" + family.frame("get_weather", [("location", "Paris"), ("days", "3")]) + "\n"
            + family.frame("write_file", [("path", "a.py"), ("content", "print('x')\n")]) + "\nDone."
        let served = try await Self.serve(family, text, chunk: chunk)
        let whole = try await Self.serve(family, text, clientStreams: false, chunk: chunk)
        #expect(served.error == nil && whole.error == nil, "\(String(describing: served.error ?? whole.error))")
        #expect(served.content == whole.content)
        #expect(served.calls.map(\.name) == ["get_weather", "write_file"])
        for (streamed, complete) in zip(served.calls, whole.calls) {
            #expect(try Self.decoded(streamed.arguments) == Self.decoded(complete.arguments))
        }
    }

    /// MiMo with thinking off refuses a thought before any call leaves, as
    /// the complete-call path does; framing whitespace is not a thought.
    @Test func mimoWithThinkingOffRefusesAThoughtBeforeTheCall() async throws {
        let call = Family.mimo.frame("get_weather", [("location", "Paris")])
        let plain = try await Self.serve(.mimo, call, mimoThinking: false)
        #expect(plain.error == nil && plain.calls.map(\.name) == ["get_weather"] && plain.toolDeltas.count > 1)
        for choice in [OpenAIToolChoice.mode(.auto), .mode(.required)] {
            let thought = try await Self.serve(.mimo, "<think>Let me see.</think>" + call, choice: choice,
                mimoThinking: false)
            let whole = try await Self.serve(.mimo, "<think>Let me see.</think>" + call, choice: choice,
                clientStreams: false, mimoThinking: false)
            #expect(thought.error != nil && whole.error != nil)
            #expect(thought.toolDeltas.isEmpty && thought.reasoning.isEmpty, "nothing left before the refusal")
        }
    }

    /// Reasoning the request does not show is withheld; the call still
    /// streams, and a frame the thought mentions stays inert.
    @Test(arguments: Family.all)
    func withheldReasoningStillStreamsTheCall(family: Family) async throws {
        let mention = family.frame("write_file", [("path", "not.py"), ("content", "example")])
        let call = family.frame("get_weather", [("location", "Paris")])
        let text = (family.nativeMiMoChannels ? "<think>" : "") + "Hmm. " + mention + "</think>" + call
        let served = try await Self.serve(family.thinking, text, withholdReasoning: true)
        #expect(served.error == nil, "\(String(describing: served.error))")
        #expect(served.reasoning.isEmpty)
        #expect(served.calls.map(\.name) == ["get_weather"] && served.toolDeltas.count > 1)
    }

    /// The forced rules hold while the call streams: text outside the call is
    /// refused, framing whitespace is not an answer, a call that fails after
    /// it started is refused with its check (never finished), a response
    /// without a call is refused, another function is never exposed, and a
    /// cut at the token limit ends `length`.
    @Test(arguments: Family.all)
    func forcedStreamsKeepTheForcedRules(family: Family) async throws {
        let call = family.frame("get_weather", [("location", "Paris")])
        let text = try await Self.serve(family, "Sure! " + call, choice: .mode(.required))
        #expect(text.error.map { "\($0)".contains("visible text") } == true, "\(String(describing: text.error))")
        let spaced = try await Self.serve(family, "\n" + call + "\n", choice: .mode(.required))
        #expect(spaced.error == nil && spaced.finishReason == "tool_calls", "\(String(describing: spaced.error))")
        let head = String(family.frame("write_file", [("path", "a.py"), ("content", "print(")]).dropLast(30))
        let open = try await Self.serve(family, head, choice: .mode(.required))
        #expect(open.check == .unterminated, "\(String(describing: open.error))")
        #expect(open.calls.first?.name == "write_file", "it had started streaming")
        #expect(open.finishReason == nil, "never finished")
        let none = try await Self.serve(family, "\n", choice: .mode(.required))
        #expect(none.error != nil)
        let named = try await Self.serve(family, family.frame("write_file", [("path", "a.py"), ("content", "x")]),
            choice: .function(name: "get_weather"))
        #expect(named.error != nil && named.calls.isEmpty, "another function is never exposed")
        let cut = try await Self.serve(family, head, choice: .mode(.required), finishReason: "length")
        #expect(cut.error == nil, "\(String(describing: cut.error))")
        #expect(cut.finishReason == "length")
        #expect(cut.calls.first?.name == "write_file", "the call stays open with what it sent")
    }

    /// `auto`: a call that fails after it started is refused with its check,
    /// never closed or finished (`FailedStreamedCallPolicy`).
    @Test(arguments: Family.all)
    func autoCallsThatFailAfterTheyStartedAreRefused(family: Family) async throws {
        let head = String(family.frame("write_file", [("path", "a.py"), ("content", "print(")]).dropLast(30))
        let open = try await Self.serve(family, head)
        #expect(open.check == .unterminated, "\(String(describing: open.error))")
        #expect(open.calls.first?.name == "write_file")
        #expect(open.finishReason == nil)
        let duplicate = try await Self.serve(family,
            family.frame("write_file", [("path", "a.py"), ("path", "b.py"), ("content", "x")]))
        // MiMo's and Nemotron's parsers refuse the frame; Qwen's keeps one
        // value, which is not the one that left.
        #expect(duplicate.check == .malformed || duplicate.check == .diverged,
            "\(String(describing: duplicate.error))")
        #expect(duplicate.finishReason == nil)
    }

    /// MiMo's frame that never named a declared function fails as on the
    /// complete-call path, and its text never leaves.
    @Test func mimoFramesThatFailBeforeExposureNeverLeaveAsText() async throws {
        let undeclared = try await Self.serve(.mimo, "Hi. " + Family.mimo.frame("rm_rf", [("path", "/")]))
        #expect(undeclared.error != nil)
        #expect(!undeclared.content.contains("tool_call"), "\(undeclared.content)")
        let whole = try await Self.serve(.mimo, "Hi. " + Family.mimo.frame("rm_rf", [("path", "/")]),
            clientStreams: false)
        #expect(whole.error != nil)
    }

    /// A cut that ends `length` keeps a started call open; text before it stays.
    @Test(arguments: Family.all)
    func autoCutsEndLengthWithTheCallLeftOpen(family: Family) async throws {
        let head = String(family.frame("write_file", [("path", "a.py"), ("content", "print(")]).dropLast(30))
        let cut = try await Self.serve(family, "Writing.\n" + head, finishReason: "length")
        #expect(cut.error == nil, "\(String(describing: cut.error))")
        #expect(cut.finishReason == "length")
        #expect(cut.content.hasPrefix("Writing."))
        #expect(cut.calls.first?.name == "write_file")
    }

    /// Native reasoning leaves first, as reasoning, and a call it mentions
    /// stays reasoning; the real call after it streams.
    @Test(arguments: Family.all)
    func nativeReasoningLeavesBeforeTheCall(family: Family) async throws {
        let mention = family.frame("write_file", [("path", "not.py"), ("content", "example")])
        let thought = "I should check. " + mention
        let call = family.frame("get_weather", [("location", "Paris")])
        let text = (family.nativeMiMoChannels ? "<think>" : "") + thought + "</think>" + call
        for choice in [OpenAIToolChoice.mode(.auto), .mode(.required)] {
            let served = try await Self.serve(family.thinking, text, choice: choice)
            #expect(served.error == nil, "\(String(describing: served.error))")
            #expect(served.reasoning == thought)
            #expect(served.calls.map(\.name) == ["get_weather"])
            let firstTool = served.chunks.firstIndex { $0.toolCallsDelta != nil }
            let lastReasoning = served.chunks.lastIndex { $0.reasoningDelta?.isEmpty == false }
            #expect(firstTool != nil && lastReasoning != nil && lastReasoning! < firstTool!)
        }
    }

    /// `auto` text before and after calls stays text, in order.
    @Test(arguments: Family.all)
    func autoTextAroundCallsStaysText(family: Family) async throws {
        let call = family.frame("get_weather", [("location", "Paris")])
        let served = try await Self.serve(family, "Checking the weather.\n" + call + "\nDone.")
        let whole = try await Self.serve(family, "Checking the weather.\n" + call + "\nDone.", clientStreams: false)
        #expect(served.error == nil && whole.error == nil)
        #expect(served.content == whole.content, "\(served.content)")
        #expect(served.content.hasPrefix("Checking the weather."))
        #expect(served.calls.first?.name == "get_weather")
        let firstTool = served.chunks.firstIndex { $0.toolCallsDelta != nil }!
        #expect(served.chunks[..<firstTool].compactMap(\.contentDelta).joined().hasPrefix("Checking the weather."))
    }

    /// Two calls stream with their own indexes; `parallel_tool_calls: false`
    /// keeps the first only, as on the complete-call path.
    @Test(arguments: Family.all)
    func twoCallsStreamAndParallelFalseHolds(family: Family) async throws {
        let text = family.frame("get_weather", [("location", "Paris")]) + "\n"
            + family.frame("write_file", [("path", "a.py"), ("content", "x")])
        for choice in [OpenAIToolChoice.mode(.auto), .mode(.required)] {
            let both = try await Self.serve(family, text, choice: choice)
            #expect(both.error == nil, "\(String(describing: both.error))")
            #expect(both.calls.map(\.name) == ["get_weather", "write_file"])
            #expect(try Self.decoded(both.calls[1].arguments) == ["path": .string("a.py"), "content": .string("x")])
            let whole = try await Self.serve(family, text, choice: choice, clientStreams: false)
            #expect(whole.calls.map(\.name) == both.calls.map(\.name))
            let first = try await Self.serve(family, text, choice: choice, parallel: false)
            let firstWhole = try await Self.serve(family, text, choice: choice, parallel: false, clientStreams: false)
            #expect(first.calls.map(\.name) == firstWhole.calls.map(\.name))
            #expect(first.calls.map(\.name) == ["get_weather"])
            #expect((first.error == nil) == (firstWhole.error == nil))
        }
    }
}

/// The scheduler's event stream with a family's native channel set-up, as
/// `MultiModelBatchSchedulerEngine`'s text path makes it.
struct NativeRoutedEngine: MLXServerEngine {
    let upstream: AsyncStream<GenerationEvent>
    let family: NativeStreamedToolCallTests.Family
    var streamToolCalls = true
    var streamNative = true
    var mimoThinking = true
    var withholdReasoning = false

    func availableModels() async throws -> [MLXServerModel] { [] }

    func streamChatCompletion(
        request: OpenAIChatCompletionRequest
    ) async throws -> AsyncThrowingStream<MLXServerGenerationEvent, Error> {
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: family.modelType)
        let handler = try ToolStreamPreparation.makeHandler(
            request: request, prepared: prepared, modelType: family.modelType, streamToolCalls: streamToolCalls,
            streamNativeToolCalls: streamNative)
        return try MultiModelBatchSchedulerEngine(registryProvider: { [:] })._testMakeEventStream(
            upstream: upstream, cancelUpstream: {}, prepared: prepared,
            releaseBox: OneShotRelease(release: { _ in }, modelId: request.model),
            toolHandler: handler, nativeReasoningPrefix: family.nativePrefix,
            preserveInnerReasoningSpans: family.preserveInnerReasoningSpans,
            absorbStrayThinkClose: family.absorbStrayThinkClose, nativeMiMoChannels: family.nativeMiMoChannels,
            nativeMiMoThinkingEnabled: mimoThinking, withholdReasoning: withholdReasoning)
    }

    func tokenize(_ request: TokenizeRequest) async throws -> TokenizeResponse { .init(tokens: []) }
    func detokenize(_ request: DetokenizeRequest) async throws -> DetokenizeResponse { .init(text: "") }
    func applyTemplate(_ request: ApplyTemplateRequest) async throws -> TokenizeResponse { .init(tokens: []) }
}

actor NativeFrameLog {
    private(set) var frames: [String] = []

    func append(_ frame: String) { frames.append(frame) }

    /// Polls for a frame carrying `tool_calls`; false after about two seconds.
    func waitForToolFrame() async -> Bool {
        for _ in 0..<400 {
            if frames.contains(where: { $0.contains("\"tool_calls\"") }) { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }
}
