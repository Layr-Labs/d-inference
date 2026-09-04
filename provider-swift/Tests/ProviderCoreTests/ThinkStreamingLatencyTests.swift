import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// Pins the SSE contract the synthetic think-marker injections rely on
/// (`ReasoningPromptProbe`):
/// - `<think>` (Qwen3.6 TTFT fix): once the streaming think parser has
///   seen an opening tag, every reasoning delta streams the moment it
///   arrives — as `reasoning_content` — instead of buffering until
///   `</think>`.
/// - `<think></think>` (qwen3-vl / thinking-off TTFT fix): the empty pair
///   lands the parser in its marker-safe `content` state, so tagless
///   output streams per token instead of buffering until end-of-stream.
///
/// This is the ProviderCore-side guard: the parser itself lives in the
/// mlx-swift-lm submodule, so a pin here fails loudly if a submodule
/// bump ever regresses incremental streaming — and the two "documents
/// upstream behaviour" tests fail the day the parser starts streaming
/// from `undecided` on its own, which is when the injections can go.
@Suite("Think streaming latency contract")
struct ThinkStreamingLatencyTests {

    /// Minimal engine emitting a scripted event sequence.
    private struct ScriptedEngine: MLXServerEngine {
        let events: [MLXServerGenerationEvent]

        func availableModels() async throws -> [MLXServerModel] { [] }
        func streamChatCompletion(
            request: OpenAIChatCompletionRequest
        ) async throws -> AsyncThrowingStream<MLXServerGenerationEvent, Error> {
            AsyncThrowingStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
        func tokenize(_ request: TokenizeRequest) async throws -> TokenizeResponse {
            TokenizeResponse(tokens: [])
        }
        func detokenize(_ request: DetokenizeRequest) async throws -> DetokenizeResponse {
            DetokenizeResponse(text: "")
        }
        func applyTemplate(_ request: ApplyTemplateRequest) async throws -> TokenizeResponse {
            TokenizeResponse(tokens: [])
        }
    }

    private func collectFrames(
        events: [MLXServerGenerationEvent]
    ) async throws -> [String] {
        let service = MLXOpenAIService(engine: ScriptedEngine(events: events))
        var request = OpenAIChatCompletionRequest(
            model: "qwen3.6-test",
            messages: [OpenAIChatMessage(role: .user, content: .text("hi"))]
        )
        request.stream = true
        request.reasoningParser = .qwen3
        var frames: [String] = []
        for try await frame in try await service.streamChatCompletionFrames(request: request) {
            frames.append(frame)
        }
        return frames
    }

    @Test("after a synthetic <think> open, each reasoning delta streams as it arrives")
    func reasoningStreamsIncrementally() async throws {
        // The injected marker, then the model's close-only thinking output
        // split across chunks — exactly what the engine emits for a
        // Qwen3.6 request whose template pre-opened the think block.
        let frames = try await collectFrames(events: [
            .content("<think>"),
            .content("step one "),
            .content("step two "),
            .content("step three</think>Answer"),
            .info(.init(
                promptTokens: 5, completionTokens: 4,
                promptTime: 0, generationTime: 0, stopReason: "stop")),
        ])

        // Reasoning must arrive across MULTIPLE frames (incremental), not
        // one buffered flush after the close.
        let reasoningFrames = frames.filter { $0.contains("\"reasoning_content\"") }
        #expect(reasoningFrames.count >= 2)
        // The first reasoning delta precedes the visible answer.
        let firstReasoning = frames.firstIndex { $0.contains("\"reasoning_content\"") }
        let answer = frames.firstIndex { $0.contains("Answer") }
        #expect(firstReasoning != nil && answer != nil)
        if let firstReasoning, let answer {
            #expect(firstReasoning < answer)
        }
        // Neither marker ever reaches a consumer.
        let joined = frames.joined()
        #expect(!joined.contains("<think>"))
        #expect(!joined.contains("</think>"))
    }

    @Test("without an opening tag, close-only reasoning buffers until the close (the bug the injection fixes)")
    func closeOnlyStillBuffersWithoutOpen() async throws {
        // Documents WHY the engine injects `<think>` for a pre-opened
        // prompt: this is upstream's behavior when no opening tag is ever
        // seen. If a submodule bump makes the parser stream close-only
        // output incrementally on its own, this fails and the `.preOpened`
        // injection (ReasoningPromptProbe) can be removed. The tagless
        // counterpart below documents the `.notPreOpened` empty-pair case.
        let frames = try await collectFrames(events: [
            .content("step one "),
            .content("step two "),
            .content("step three</think>Answer"),
            .info(.init(
                promptTokens: 5, completionTokens: 4,
                promptTime: 0, generationTime: 0, stopReason: "stop")),
        ])

        let reasoningFrames = frames.filter { $0.contains("\"reasoning_content\"") }
        #expect(reasoningFrames.count == 1)
    }

    @Test("without any tag, tagless output buffers whole until finish (documents upstream `.undecided`)")
    func taglessStillBuffersWithoutMarker() async throws {
        // Documents WHY the engine injects the EMPTY PAIR for prompts that
        // did not pre-open a think block: upstream's `.undecided` state
        // buffers tagless output until end-of-stream, so a qwen3-vl
        // instruct response (never emits a tag) would reach the consumer
        // as one flush at generation end. This is a scripted engine —
        // it bypasses `MultiModelBatchSchedulerEngine.makeEventStream`
        // where the injection lives — so it stays green after the fix.
        // If a submodule bump makes the parser stream `.undecided` on its
        // own, this fails and the empty-pair injection can be retired.
        let frames = try await collectFrames(events: [
            .content("Hello"),
            .content(" world"),
            .content("!"),
            .info(.init(
                promptTokens: 5, completionTokens: 3,
                promptTime: 0, generationTime: 0, stopReason: "stop")),
        ])

        let content = frames
            .compactMap(ProviderLoop.parseStreamChunk)
            .compactMap(\.contentDelta)
            .filter { !$0.isEmpty }
        // ONE coalesced flush, not three per-token deltas.
        #expect(content == ["Hello world!"])
    }

    @Test("after a synthetic empty pair, tagless content streams per token")
    func emptyPairUnlocksPerTokenContent() async throws {
        // The parser-side contract the `.notPreOpened` injection relies on:
        // `<think></think>` is two empty-span transitions (nothing emitted)
        // that land the parser in its marker-safe `content` state.
        let frames = try await collectFrames(events: [
            .content("<think></think>"),
            .content("Hello"),
            .content(" world"),
            .content("!"),
            .info(.init(
                promptTokens: 5, completionTokens: 3,
                promptTime: 0, generationTime: 0, stopReason: "stop")),
        ])

        let chunks = frames.compactMap(ProviderLoop.parseStreamChunk)
        let content = chunks.compactMap(\.contentDelta).filter { !$0.isEmpty }
        #expect(content == ["Hello", " world", "!"])
        #expect(chunks.allSatisfy { $0.reasoningDelta == nil })
        let joined = frames.joined()
        #expect(!joined.contains("<think>"))
        #expect(!joined.contains("</think>"))
    }
}

// MARK: - Live-isolated tier: scripted CBv2 engine → real bridge → real framer

/// Drives the REAL streaming path the coordinator handler uses — a scripted
/// `CBv2Engine` behind a real `EngineV2Bridge`, a
/// `MultiModelBatchSchedulerEngine` registry entry and
/// `MLXOpenAIService.streamChatCompletionFrames` — so the injection in
/// `makeEventStream` is exercised rather than bypassed (the scripted
/// `MLXServerEngine` suite above cannot reach it).
@Suite("Think injection through the real engine stream")
struct ThinkInjectionEngineStreamTests {

    /// Yields one delta per scripted text (one token each), then a clean
    /// stop — the shape EngineLoopV2 emits for a tagless instruct answer.
    private final class ScriptedDeltaEngine: CBv2Engine, @unchecked Sendable {
        private let deltas: [String]
        init(deltas: [String]) { self.deltas = deltas }

        func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
            let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
            for (index, text) in deltas.enumerated() {
                continuation.yield(.delta(text: text, tokens: [100 + index], logprobs: nil))
            }
            continuation.yield(.finished(
                reason: .stop,
                usage: CBv2Usage(promptTokens: 3, completionTokens: deltas.count)))
            continuation.finish()
            return stream
        }
        func cancel(_ id: CBv2RequestID) {}
        func capacity() -> CBv2CapacitySnapshot {
            .init(
                activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0,
                kvBytesCapacity: 0, activeTokens: 0)
        }
        func shutdown() async {}
    }

    /// Fixed-template tokenizer whose decoded prompt tail is scripted, so
    /// the probe sees exactly the tail a real chat template would render.
    private struct TailTokenizer: MLXLMCommon.Tokenizer {
        let tail: String
        func encode(text: String, addSpecialTokens: Bool) -> [Int] { [1] }
        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { tail }
        func convertTokenToId(_ token: String) -> Int? { nil }
        func convertIdToToken(_ id: Int) -> String? { nil }
        var bosToken: String? { nil }
        var eosToken: String? { nil }
        var unknownToken: String? { nil }
        func applyChatTemplate(
            messages: [[String: any Sendable]],
            tools: [[String: any Sendable]]?,
            additionalContext: [String: any Sendable]?
        ) throws -> [Int] { [1, 2, 3] }
    }

    private static let plainTail = "<|im_start|>assistant\n"
    private static let preClosedTail = "<|im_start|>assistant\n<think>\n\n</think>\n\n"
    private static let preOpenedTail = "<|im_start|>assistant\n<think>\n"

    private struct Collected {
        let frames: [String]
        var content: [String] {
            frames.compactMap(ProviderLoop.parseStreamChunk)
                .compactMap(\.contentDelta).filter { !$0.isEmpty }
        }
        var reasoning: [String] {
            frames.compactMap(ProviderLoop.parseStreamChunk)
                .compactMap(\.reasoningDelta).filter { !$0.isEmpty }
        }
        /// Content-bearing frames delivered BEFORE the trailing usage frame —
        /// the coordinator's first-content clock stops on the first of them.
        var contentFramesBeforeUsage: Int {
            var count = 0
            for frame in frames {
                guard let parsed = ProviderLoop.parseStreamChunk(frame) else { continue }
                if parsed.usage != nil { break }
                if let content = parsed.contentDelta, !content.isEmpty { count += 1 }
            }
            return count
        }
        var leaksMarker: Bool {
            let joined = frames.joined()
            return joined.contains("<think>") || joined.contains("</think>")
        }
    }

    private func stream(tail: String, deltas: [String]) async throws -> Collected {
        let tokenizer = TokenizerHandle(TailTokenizer(tail: tail))
        let bridge = EngineV2Bridge(
            engine: ScriptedDeltaEngine(deltas: deltas),
            modelId: "qwen3-vl-test",
            tokenizer: tokenizer,
            eosTokenIds: [])
        let entry = MultiModelBatchSchedulerEngine.ModelRegistryEntry(
            tokenizer: tokenizer, engineV2Bridge: bridge)
        let engine = MultiModelBatchSchedulerEngine(
            registryProvider: { @Sendable in ["qwen3-vl-test": entry] })
        let service = MLXOpenAIService(engine: engine)
        var request = OpenAIChatCompletionRequest(
            model: "qwen3-vl-test",
            messages: [OpenAIChatMessage(role: .user, content: .text("hi"))])
        // The coordinator handler forces both of these for every request
        // (`ProviderLoop+InferenceHandler`): streaming, usage on the tail,
        // and `.qwen3` for nil/unknown/qwen* model types.
        request.stream = true
        request.reasoningParser = .qwen3
        request.streamOptions = OpenAIStreamOptions(includeUsage: true)
        var frames: [String] = []
        for try await frame in try await service.streamChatCompletionFrames(request: request) {
            frames.append(frame)
        }
        return Collected(frames: frames)
    }

    @Test("a prompt that did not pre-open a think block streams tagless content per token")
    func taglessStreamsPerTokenWithoutPreOpen() async throws {
        // qwen3-vl instruct / thinking-off shape: the template ends at the
        // assistant header and the model never emits a think tag. Without
        // the empty pair the parser parks in `.undecided` and the ONLY
        // content frame is the finish-time flush — TTFT == generation time.
        let out = try await stream(tail: Self.plainTail, deltas: ["Hello", " world", "!"])
        #expect(out.contentFramesBeforeUsage >= 2)
        #expect(out.content == ["Hello", " world", "!"])
        #expect(out.reasoning.isEmpty)
        #expect(!out.leaksMarker)
    }

    @Test("a pre-closed thinking-off tail streams tagless content per token")
    func preClosedTailStreamsPerToken() async throws {
        // Qwen with enable_thinking=false embeds an EMPTY closed block in the
        // prompt; output is pure content and an orphan close cannot occur.
        let out = try await stream(tail: Self.preClosedTail, deltas: ["Hello", " world", "!"])
        #expect(out.contentFramesBeforeUsage >= 2)
        #expect(out.content == ["Hello", " world", "!"])
        #expect(!out.leaksMarker)
    }

    @Test("a pre-opened tail still injects only the open and streams reasoning incrementally")
    func preOpenedTailStreamsReasoning() async throws {
        let out = try await stream(
            tail: Self.preOpenedTail,
            deltas: ["step one ", "step two ", "</think>Answer"])
        #expect(out.reasoning.count >= 2)
        #expect(out.content == ["Answer"])
        #expect(!out.leaksMarker)
    }

    @Test("after the empty pair a model-emitted <think> block still splits into reasoning")
    func modelEmittedThinkStillSplitsAfterEmptyPair() async throws {
        // The pair lands the parser in its marker-safe `content` state: a
        // later model-emitted block flips to reasoning and back exactly as
        // it does for a thinking model after `</think>`.
        let out = try await stream(
            tail: Self.plainTail,
            deltas: ["Hi", "<think>", "hmm", "</think>", "Bye"])
        #expect(out.content == ["Hi", "Bye"])
        #expect(out.reasoning == ["hmm"])
        #expect(!out.leaksMarker)
    }
}
