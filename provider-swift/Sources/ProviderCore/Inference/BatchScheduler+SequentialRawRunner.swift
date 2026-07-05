// Copyright © 2026 Eigen Labs.
//
// Raw-text single-sequence runner for sequential-serving models (DeepSeek-V4:
// no batched-engine cache-layout support at all — see `requiresSequentialServing`).
//
// `runGreedyFastPath` (BatchScheduler+B1FastPath.swift) drives its decode loop
// through `ModelContainer.generate`, which attaches mlx-swift-lm's
// `TextToolTokenLoopHandler` (tool-call format defaulting to `.json`). That
// handler can CONSUME generated text into a `.toolCall` event whenever it
// parses something that looks like a tool call — which is wrong for the
// sequential route on TWO counts:
//
//   1. Tool-bearing requests: the provider's own tool parsing runs downstream
//      on RAW text chunks (`MultiModelBatchSchedulerEngine.streamChatCompletion`
//      -> `BatchedToolStreamHandler.processChunk`). A second, independent
//      tool-call parser upstream would either double-consume the call text or
//      disagree with the downstream parser's format, and `runGreedyFastPath`
//      hard-fails outright the moment it sees a `.toolCall` event.
//   2. Non-tool requests: an unscoped false-positive parse (the model simply
//      emitting JSON-looking text with no tools declared) would ALSO trip
//      that same hard-fail — there is no tool contract to have violated, but
//      the text-loop can't tell the difference.
//
// So every sequential-serving request — tool-bearing or not — must run
// through a text loop that never tool-parses. mlx-swift-lm's public
// `generateTokens(input:cache:parameters:context:...)` (Evaluate.swift) is
// exactly that: it drives the SAME `TokenIterator` (prefill, sampling,
// cancellation, KV quant, EOS/length stop-reason detection) but through
// `RawTokenLoopHandler`, which yields raw token IDs only — no detokenization,
// no tool parsing, `Generation.toolCall` cannot occur. We detokenize
// incrementally ourselves via the same public `NaiveStreamingDetokenizer`
// `TextToolTokenLoopHandler` uses internally, so the emitted text chunks are
// byte-identical to what the tool-aware loop would have produced absent any
// tool-call detection.
//
// No mlx-swift-lm changes were needed for this — `generateTokens`,
// `ModelContainer.perform(values:_:)`, and `NaiveStreamingDetokenizer` are all
// public API.

import Foundation
import MLX
import MLXLMCommon
import MLXRandom

extension BatchScheduler {

    /// Which decode loop a single-exclusive admission should run through.
    /// Pure + static so the dispatch decision is unit-testable without a
    /// model. Sequential-serving models ALWAYS take the raw-text loop
    /// (`rawTextLoop`), independent of whether the request carries tools —
    /// see the file header for why a tool-aware text loop is unsafe for
    /// EITHER case on that route. The Gemma B=1 greedy fast path is the only
    /// caller of the tool-aware `container.generate` loop, and only reaches
    /// it via its own `allowFastPath` eligibility gate.
    enum FastPathRunnerKind: Equatable {
        case rawTextLoop
        case toolAwareGenerate
    }

    static func fastPathRunnerKind(useSequential: Bool) -> FastPathRunnerKind {
        useSequential ? .rawTextLoop : .toolAwareGenerate
    }

    /// Drive a single sequential-serving request through mlx-swift-lm's raw
    /// token loop (`generateTokens`) and translate it onto the scheduler's
    /// `GenerationEvent` stream. Mirrors `runGreedyFastPath`'s lifecycle
    /// (admission / first-token / finish bookkeeping, cancellation,
    /// billing-safe token counts, finish-reason semantics, KV release) —
    /// the only difference is the source of tokens/text: raw `TokenGeneration`
    /// + manual incremental detokenization instead of `Generation` events
    /// that may carry a parsed (and text-consuming) tool call.
    ///
    /// The spawned task is tracked in `fastPathTasks[id]` exactly like the
    /// greedy fast path, so `cancel` / `cancelAll` / `stopCurrentEngine` tear
    /// it down the same way. The caller (`submitTokenized`) is responsible
    /// for having inserted the bridge and reserved KV before this runs, and
    /// for wiring `continuation.onTermination`.
    func runSequentialRawTextPath(
        requestId id: String,
        container: ModelContainer,
        tokenizer: TokenizerHandle,
        promptTokens: [Int],
        maxTokens: Int,
        parameters: GenerateParameters,
        seed: UInt64? = nil,
        continuation: AsyncStream<GenerationEvent>.Continuation
    ) {
        let scheduler = self
        let promptCount = promptTokens.count
        let task = Task {
            // Same exclusive-path RNG-seed contract as `runGreedyFastPath`:
            // safe only because the sequential route is single-request-
            // exclusive (the admission gate rejects any concurrent work).
            if let seed { MLXRandom.seed(seed) }

            await scheduler.recordAdmission(requestId: id, at: .now)

            let tokenStream: AsyncStream<TokenGeneration>
            do {
                // `perform(values:_:)` runs the closure inside the container's
                // serial-access isolation (prefill happens synchronously
                // inside `generateTokens` -> `TokenIterator.init`, i.e. still
                // "inside the task", matching the tool-aware fast path). Only
                // `promptTokens` ([Int], Sendable) crosses the boundary; the
                // resulting `AsyncStream<TokenGeneration>` is Sendable since
                // `TokenGeneration` is.
                tokenStream = try await container.perform(values: promptTokens) { context, tokens in
                    let input = LMInput(tokens: MLXArray(tokens))
                    return try MLXLMCommon.generateTokens(
                        input: input,
                        parameters: parameters,
                        context: context
                    )
                }
            } catch {
                _ = await scheduler.recordFinish(
                    requestId: id, promptTokens: promptCount,
                    completionTokens: 0, success: false)
                continuation.yield(.error(
                    "sequential generation failed: \(error.localizedDescription)"))
                continuation.finish()
                await scheduler.clearFastPathTask(id)
                return
            }

            var sawFirstToken = false
            // Same running-tally rationale as `runGreedyFastPath`: the
            // terminal `.info` only arrives on a clean finish, so a
            // cancellation needs a lower-bound token count for billing.
            var streamedTokens = 0
            var terminalCompletion: Int? = nil
            var reportedPrompt = promptCount
            var detokenizer = NaiveStreamingDetokenizer(tokenizer: tokenizer.inner)

            for await gen in tokenStream {
                // Cooperative cancellation: mirrors `runGreedyFastPath`.
                if Task.isCancelled { break }
                switch gen {
                case .token(let tokenId):
                    if !sawFirstToken {
                        sawFirstToken = true
                        await scheduler.recordFirstToken(requestId: id, at: .now)
                    }
                    streamedTokens += 1
                    detokenizer.append(token: tokenId)
                    // `next()` returns nil while the tail is an incomplete
                    // unicode codepoint (surrogate/multi-byte); it is
                    // completed and emitted once enough tokens land. Matches
                    // `TextToolTokenLoopHandler`'s per-token detokenize call.
                    if let text = detokenizer.next(), !text.isEmpty {
                        continuation.yield(.chunk(text))
                    }
                case .info(let info):
                    reportedPrompt = info.promptTokenCount
                    terminalCompletion = info.generationTokenCount
                }
            }

            let cancelled = Task.isCancelled
            let completionTokens = max(terminalCompletion ?? 0, streamedTokens)
            // No `.toolCall` case exists on `TokenGeneration` — the raw loop
            // physically cannot surface one, so success only depends on
            // cancellation (unlike `runGreedyFastPath`'s `sawToolCall` check).
            let succeeded = !cancelled
            let usage = await scheduler.recordFinish(
                requestId: id,
                promptTokens: reportedPrompt,
                completionTokens: completionTokens,
                success: succeeded)

            if !succeeded, usage.promptTokens > 0 || usage.completionTokens > 0 {
                continuation.yield(.info(
                    promptTokens: usage.promptTokens,
                    completionTokens: usage.completionTokens,
                    tokensPerSecond: usage.tps,
                    finishReason: nil))
            }
            if cancelled {
                continuation.yield(.error("request cancelled"))
            } else {
                // Same length-vs-stop heuristic as `runGreedyFastPath` (kept
                // identical rather than switching to `GenerateCompletionInfo
                // .stopReason` for behavioral parity between the two runners).
                continuation.yield(.info(
                    promptTokens: usage.promptTokens,
                    completionTokens: usage.completionTokens,
                    tokensPerSecond: usage.tps,
                    finishReason: usage.completionTokens >= maxTokens ? "length" : "stop"))
            }
            continuation.finish()
            await scheduler.clearFastPathTask(id)
        }
        fastPathTasks[id] = task
    }
}
