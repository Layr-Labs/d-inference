// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

/// Streams one clause verbatim, one token per delta. A cancel ends the row
/// with the engine's `.cancelled` terminal; a row nobody cancels ends as
/// `.length` after a short wait, like a row that reached its cap.
private final class LoopingCBv2Engine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<CBv2Event>.Continuation?
    private var cancels = 0
    private var promptTokens = 0
    let tokens: Int

    init(tokens: Int) { self.tokens = tokens }

    var cancelCount: Int { lock.withLock { cancels } }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let clause = QwenByteTestTokenizer.tokens("Wait, the reaction is: CO + Cu -> CO2 + Cu (No). ")
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        lock.withLock {
            self.continuation = continuation
            promptTokens = request.promptTokens.count
        }
        for index in 0..<tokens {
            let token = clause[index % clause.count]
            continuation.yield(.delta(
                text: String(decoding: QwenByteTestTokenizer.piece(token), as: UTF8.self),
                tokens: [token], logprobs: nil))
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.finish(.length)
        }
        return stream
    }

    private func finish(_ reason: CBv2FinishReason) {
        let (continuation, prompt) = lock.withLock {
            defer { self.continuation = nil }
            return (self.continuation, promptTokens)
        }
        continuation?.yield(.finished(
            reason: reason, usage: CBv2Usage(promptTokens: prompt, completionTokens: tokens)))
        continuation?.finish()
    }

    func cancel(_ id: CBv2RequestID) {
        lock.withLock { cancels += 1 }
        finish(.cancelled)
    }

    func capacity() -> CBv2CapacitySnapshot {
        .init(activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0, kvBytesCapacity: 0, activeTokens: 0)
    }

    func shutdown() async {}
}

@Suite("Loop guard through the scheduler's text path")
struct GenerationLoopGuardServingTests {
    private let modelID = "EigenLabs/Qwen3.5-9B-MLX-4bit-mtp"
    private static let tokenizer = TokenizerHandle(QwenByteTestTokenizer())

    private struct Outcome {
        var content = ""
        var reasoning = ""
        var info: ServerGenerationInfo?
        var error: (any Error)?
    }

    private func serve(_ engine: LoopingCBv2Engine, modelType: String = "qwen3_5", fields: String = "")
        async throws -> Outcome {
        let bridge = EngineV2Bridge(engine: engine, modelId: modelID, tokenizer: Self.tokenizer,
            eosTokenIds: [248046, 248044], defaultMaxTokens: 64, maxConcurrentRequests: 1)
        let id = modelID
        let tokenizer = Self.tokenizer
        var scheduler = MultiModelBatchSchedulerEngine(registryProvider: {
            [id: .init(tokenizer: tokenizer, modelType: modelType, engineV2Bridge: bridge)]
        })
        // The guard alone, whatever the runner's DARKBLOOM_LOOP_EXIT_THINKING (the exit has its own suites).
        scheduler.exitThinkingSetting = .off
        let request = try JSONDecoder().decode(OpenAIChatCompletionRequest.self, from: Data("""
        {"model":"\(modelID)","messages":[{"role":"user","content":"hi"}],"reasoning_parser":"qwen3",\
        "max_tokens":8192\(fields)}
        """.utf8))
        var outcome = Outcome()
        var parser = StreamingReasoningParser(format: .qwen3)
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
        await bridge.shutdown()
        return outcome
    }

    @Test("a reasoning loop is stopped in the engine and ends as length, with no answer and no error")
    func reasoningLoopEndsAsLength() async throws {
        let engine = LoopingCBv2Engine(tokens: 4_200)
        let outcome = try await serve(engine)
        #expect(engine.cancelCount == 1)
        #expect(outcome.error == nil)
        #expect(outcome.info?.stopReason == "length")
        #expect(outcome.info?.completionTokens == 4_200)
        #expect(outcome.content.isEmpty)
        // Every token's text reaches the client, the in-flight ones after the stop included.
        #expect(outcome.reasoning.hasPrefix("Wait, the reaction is:"))
        #expect(outcome.reasoning.utf8.count > 4_096)
    }

    @Test("a model type off the list keeps today's behavior")
    func unlistedModelTypeIsNotGuarded() async throws {
        let engine = LoopingCBv2Engine(tokens: 4_200)
        let outcome = try await serve(engine, modelType: "llama")
        #expect(engine.cancelCount == 0)
        #expect(outcome.info?.stopReason == "length")
    }
}
