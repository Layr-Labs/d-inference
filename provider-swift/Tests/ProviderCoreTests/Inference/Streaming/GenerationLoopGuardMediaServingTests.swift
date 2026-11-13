// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
import MLXLMCommon
import MLXLMServer
import MLXNN
import Testing

@testable import ProviderCore

/// A Gemma 4 media row (one video span in the prompt) that repeats one clause
/// verbatim, inside its thought or in its answer, one token per delta; the
/// guard's cancel ends it `.cancelled` (a row nobody cancels ends `.length`
/// after a short wait). Any later submission is the continuation: it answers
/// "Answer: B" and stops.
private final class MediaThoughtLoopCBv2Engine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncStream<CBv2Event>.Continuation] = []
    private var submitted: [CBv2Request] = []
    private var produced: [[Int]] = []
    private var cancels = 0
    let loopInsideThought: Bool

    init(loopInsideThought: Bool) { self.loopInsideThought = loopInsideThought }

    var requests: [CBv2Request] { lock.withLock { submitted } }
    var outputs: [[Int]] { lock.withLock { produced } }
    var cancelCount: Int { lock.withLock { cancels } }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        let index = lock.withLock {
            submitted.append(request)
            continuations.append(continuation)
            produced.append([])
            return submitted.count - 1
        }
        func emit(_ text: String) {
            let tokens = GemmaThoughtTestTokenizer.tokens(text)
            lock.withLock { produced[index] += tokens }
            continuation.yield(.delta(text: text, tokens: tokens, logprobs: nil))
        }
        if index == 0 {
            emit("<|channel>")
            emit("thought\n")
            if !loopInsideThought {
                emit("ok")
                emit("<channel|>")
            }
            let clause = Array("The red circle appears again. ")
            for position in 0..<4_200 {
                emit(String(clause[position % clause.count]))
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.finish(index, .length)
            }
        } else {
            for character in "Answer: B" { emit(String(character)) }
            finish(index, .stop)
        }
        return stream
    }

    private func finish(_ index: Int, _ reason: CBv2FinishReason) {
        let (continuation, prompt, completion) = lock.withLock {
            defer { continuations[index] = AsyncStream<CBv2Event>.makeStream().continuation }
            return (continuations[index], submitted[index].promptTokens.count, produced[index].count)
        }
        continuation.yield(.finished(
            reason: reason, usage: CBv2Usage(promptTokens: prompt, completionTokens: completion)))
        continuation.finish()
    }

    func cancel(_ id: CBv2RequestID) {
        let index = lock.withLock {
            cancels += 1
            return submitted.lastIndex { $0.id == id }
        }
        if let index { finish(index, .cancelled) }
    }

    func capacity() -> CBv2CapacitySnapshot {
        .init(activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0, kvBytesCapacity: 0, activeTokens: 0)
    }

    func shutdown() async {}
}

/// Never forward-passed: a real `ModelContainer` for the media path, whose
/// preparation the test plumbing supplies.
private final class MediaLoopStubLanguageModel: Module, LanguageModel {
    func prepare(_ input: LMInput, cache: [KVCache], state: LMOutput.State?, prefill: PrefillParameters) throws
        -> PrepareResult {
        .tokens(input.text)
    }
    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
}

private struct MediaLoopStubProcessor: UserInputProcessor {
    struct Unused: Error {}
    func prepare(input: UserInput) async throws -> LMInput { throw Unused() }
}

@Suite("Loop guard: image and video requests (scheduler media path)")
struct GenerationLoopGuardMediaServingTests {
    private let modelID = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
    private static let tokenizer = TokenizerHandle(GemmaThoughtTestTokenizer())
    /// The video's three soft-token placeholders, after `<|turn>user\n`.
    private static let videoPlaceholder = 2_000
    private static let promptHead = GemmaThoughtTestTokenizer.tokens("<|turn>user\n")
    private static let prompt = promptHead + Array(repeating: videoPlaceholder, count: 3)
        + GemmaThoughtTestTokenizer.tokens("How many times does the circle appear?<turn|>\n<|turn>model\n")
    private static let span = CBv2ImageSpan(tokenOffset: promptHead.count, length: 3)

    private struct Outcome {
        var content = ""
        var reasoning = ""
        var info: ServerGenerationInfo?
        var error: (any Error)?
    }

    /// One prepared video submission, as the vision tower would hand it over.
    private static func prepared() -> EngineV2VisionPrefill.PreparedSubmission {
        EngineV2VisionPrefill.PreparedSubmission(
            promptTokens: prompt, spans: [span],
            embeddings: [MLXArray(Array(0..<12).map(Float.init)).reshaped([3, 4])],
            attention: .bidirectionalSpans, positionState: nil, mediaKind: .video)
    }

    private func serve(
        _ engine: MediaThoughtLoopCBv2Engine, modelType: String = "gemma4", maxTokens: Int = 8_192
    ) async throws -> Outcome {
        let bridge = EngineV2Bridge(engine: engine, modelId: modelID, tokenizer: Self.tokenizer,
            eosTokenIds: [GemmaThoughtTestTokenizer.turnClose, GemmaThoughtTestTokenizer.eos], defaultMaxTokens: 64,
            maxConcurrentRequests: 1)
        let container = ModelContainer(context: ModelContext(
            configuration: ModelConfiguration(id: modelID), model: MediaLoopStubLanguageModel(),
            processor: MediaLoopStubProcessor(), tokenizer: GemmaThoughtTestTokenizer()))
        let id = modelID
        let tokenizer = Self.tokenizer
        let scheduler = MultiModelBatchSchedulerEngine(
            registryProvider: {
                [id: .init(tokenizer: tokenizer, modelType: modelType, container: container, isVLM: true,
                           engineV2Bridge: bridge)]
            },
            engineV2Vision: EngineV2VisionPlumbing(
                prepare: { _, _, _ in Self.prepared() }, emitTelemetry: { _ in }))
        let outcome = try await consume(scheduler, maxTokens: maxTokens)
        await bridge.shutdown()
        return outcome
    }

    private func consume(_ scheduler: MultiModelBatchSchedulerEngine, maxTokens: Int) async throws -> Outcome {
        let request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: Data("""
        {"model":"\(modelID)","messages":[{"role":"user","content":[\
        {"type":"video_url","video_url":{"url":"data:video/mp4;base64,AAAA"}},\
        {"type":"text","text":"How many times does the circle appear?"}]}],\
        "reasoning_parser":"gemma4","max_tokens":\(maxTokens)}
        """.utf8))
        var outcome = Outcome()
        var parser = StreamingReasoningParser(format: .gemma4)
        func apply(_ parsed: ParsedReasoning) {
            outcome.content += parsed.content
            outcome.reasoning += parsed.reasoningContent ?? ""
        }
        do {
            for try await event in try await scheduler.streamChatCompletion(request: request) {
                switch event {
                case .content(let text): parser.parse(text).forEach(apply)
                case .parsed(let parsed): apply(parsed)
                case .info(let info): outcome.info = info
                case .toolCall, .toolCallDelta, .logprobs: break
                }
            }
        } catch { outcome.error = error }
        parser.finish().forEach(apply)
        return outcome
    }

    @Test("a video request's loop inside the thought ends the thought; the answer continues over the same video")
    func videoThoughtLoopEndsInAnAnswer() async throws {
        let engine = MediaThoughtLoopCBv2Engine(loopInsideThought: true)
        let outcome = try await serve(engine)
        #expect(outcome.error == nil)
        #expect(engine.cancelCount == 1)
        let requests = engine.requests
        #expect(requests.count == 2)
        let first = try #require(requests.first)
        let continuation = try #require(requests.last)
        let firstOutput = try #require(engine.outputs.first)
        #expect(first.multimodal?.spans == [Self.span])
        // The same prompt with the same video span, every token the row
        // produced, then the end of thinking.
        #expect(continuation.promptTokens
            == first.promptTokens + firstOutput + [GemmaThoughtTestTokenizer.channelClose])
        #expect(continuation.multimodal?.spans == [Self.span])
        #expect(try continuation.multimodal?.embeddings().count == 1)
        #expect(continuation.maxTokens == first.maxTokens - firstOutput.count - 1)
        #expect(outcome.reasoning.hasPrefix("The red circle appears again."))
        #expect(outcome.content == "Answer: B")
        #expect(outcome.info?.stopReason == "stop")
        #expect(outcome.info?.promptTokens == first.promptTokens.count)
        #expect(outcome.info?.completionTokens == firstOutput.count + 1 + 9)
    }

    @Test("a video request's loop in the answer ends as length, with nothing more submitted")
    func videoAnswerLoopEndsAsLength() async throws {
        let engine = MediaThoughtLoopCBv2Engine(loopInsideThought: false)
        let outcome = try await serve(engine)
        #expect(outcome.error == nil)
        #expect(engine.cancelCount == 1)
        #expect(engine.requests.count == 1)
        #expect(outcome.info?.stopReason == "length")
        #expect(outcome.content.hasPrefix("The red circle appears again."))
    }

    @Test("a family outside the guard's list keeps its media rows unguarded")
    func unguardedFamilyRunsToItsOwnEnd() async throws {
        let engine = MediaThoughtLoopCBv2Engine(loopInsideThought: true)
        let outcome = try await serve(engine, modelType: "qwen3_vl")
        #expect(outcome.error == nil)
        #expect(engine.cancelCount == 0)
        #expect(engine.requests.count == 1)
        #expect(outcome.info?.stopReason == "length")
    }
}
