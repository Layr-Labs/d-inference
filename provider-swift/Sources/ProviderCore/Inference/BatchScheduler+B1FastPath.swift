// Copyright © 2026 Eigen Labs.
//
// BatchScheduler B=1 greedy fast path: an env-gated bypass of the
// continuous-batching engine for a single exclusive, greedy (temperature == 0)
// request.
//
// The batched engine carries continuous-batching overhead a single-row decode
// does not need: batch tensor (de)allocation per step, the scheduler step loop,
// the output collector, and cross-thread `RequestOutput` streaming. On Gemma-4
// that overhead shows up as ~63 TPS through `BatchedEngine` vs ~75 TPS for the
// raw single-sequence loop (see `Tests/.../Gemma4DecodeProfileTests.swift`).
//
// When exactly one request is in flight and it is pure greedy, we run that
// single-sequence decode through `ModelContainer.generate` — the SAME
// concurrency-safe path the VLM media path (`VLMRequestInference`) already uses
// alongside the engine. `ModelContainer.generate` holds the container
// exclusively only for the prefill, then streams the decode (asyncEval
// pipelined) on its own task. We translate its `Generation` events to our
// `GenerationEvent` stream.
//
// Safety posture:
//   * OFF by default; opt in with an env flag.
//   * Conservative gate — anything that isn't a single exclusive greedy text
//     request falls back to the batched engine, so the engine path's behavior
//     is never altered.
//   * KV byte budget is still reserved/released, and bridge bookkeeping
//     (heartbeats, decode/prefill EWMA, billing-safe usage) is preserved via
//     the SAME `recordAdmission` / `recordFirstToken` / `recordFinish` methods
//     the engine bridge uses.
//   * The in-flight task is tracked so `cancel` / `cancelAll` /
//     `stopCurrentEngine` tear it down deterministically.

import Foundation
import MLX
import MLXLMCommon

extension BatchScheduler {

    // MARK: - Env gate

    /// True when the operator opted into the B=1 greedy fast path. Two flags are
    /// accepted: `DARKBLOOM_B1_GREEDY_FAST_PATH` (generic) and
    /// `DARKBLOOM_GEMMA_B1_FAST_PATH` (Gemma-targeted alias). Either set to `"1"`
    /// enables it. Read per-call (cheap) so tests can toggle it via the
    /// environment without restarting the scheduler.
    static func b1GreedyFastPathEnabled() -> Bool {
        let env = ProcessInfo.processInfo.environment
        return env["DARKBLOOM_B1_GREEDY_FAST_PATH"] == "1"
            || env["DARKBLOOM_GEMMA_B1_FAST_PATH"] == "1"
    }

    // MARK: - Eligibility

    /// Whether this request can take the single-exclusive greedy fast path.
    ///
    /// MUST be evaluated BEFORE the request's own bridge is inserted into
    /// `activeBridges` — the exclusivity check reads `activeBridges.count`.
    /// Every condition is conservative: a miss simply defers to the batched
    /// engine, so this can only shrink the set of requests the fast path serves,
    /// never change the engine path's correctness. The decision itself is a pure
    /// function (`b1FastPathEligiblePure`) so it can be unit-tested exhaustively
    /// without a loaded model.
    func b1FastPathEligible(
        temperature: Float,
        topP: Float?,
        topK: Int?,
        seed: UInt64?,
        maxTokens: Int,
        cacheScope: String
    ) -> Bool {
        Self.b1FastPathEligiblePure(
            // Test override wins when set; otherwise consult the env flags.
            enabled: _forceB1FastPathForTest ?? Self.b1GreedyFastPathEnabled(),
            temperature: temperature,
            topP: topP,
            topK: topK,
            seed: seed,
            maxTokens: maxTokens,
            cacheScope: cacheScope,
            activeBridgeCount: activeBridges.count,
            pendingRequestCount: pendingRequestCount,
            hasContainer: modelContainer != nil
        )
    }

    /// Pure eligibility policy for the B=1 greedy fast path. No actor state — all
    /// inputs are parameters — so it is fully unit-testable. Order is irrelevant
    /// to the result (all conditions must hold), but kept cheapest-first.
    static func b1FastPathEligiblePure(
        enabled: Bool,
        temperature: Float,
        topP: Float?,
        topK: Int?,
        seed: UInt64?,
        maxTokens: Int,
        cacheScope: String,
        activeBridgeCount: Int,
        pendingRequestCount: Int,
        hasContainer: Bool
    ) -> Bool {
        guard enabled else { return false }
        // Pure greedy only: temperature 0 and no nucleus / top-k truncation.
        // (minP / repetition / presence / frequency penalties are not part of
        // the tokenized submit surface, so temperature + topP + topK fully
        // characterize "greedy" here.)
        guard temperature == 0 else { return false }
        guard topP == nil || topP == 0 else { return false }
        guard topK == nil || topK == 0 else { return false }
        // A seed implies sampling intent; greedy ignores it, but treat its
        // presence as "not the simple greedy case" and defer to the engine.
        guard seed == nil else { return false }
        guard maxTokens > 0 else { return false }
        // No prefix-cache scope: the fast path runs a cold prefill against a
        // fresh cache and does not participate in the checkpoint / engine prefix
        // tiers, so a scoped request keeps the engine path to retain cache reuse.
        guard cacheScope.isEmpty else { return false }
        // Exclusive: no other in-flight or queued work. Concurrent batched work
        // would defeat the single-row assumption (shared GPU + KV headroom).
        guard activeBridgeCount == 0 else { return false }
        guard pendingRequestCount == 0 else { return false }
        // Need a live container to generate against.
        guard hasContainer else { return false }
        return true
    }

    // MARK: - Runner

    /// Drive a single greedy request through `ModelContainer.generate` and
    /// translate its `Generation` events onto the scheduler's `GenerationEvent`
    /// stream. Mirrors `runBridge`'s lifecycle (admission / first-token / finish
    /// bookkeeping and terminal `.info` / `.error` mapping) but sources tokens
    /// from the single-sequence generator instead of `engine.core.streamOutputs`.
    ///
    /// The spawned task is tracked in `fastPathTasks[id]` so `cancel` /
    /// `cancelAll` / `stopCurrentEngine` can tear it down; it removes its own
    /// handle on completion. The caller (`submitTokenized`) is responsible for
    /// having inserted the bridge and reserved KV before this runs, and for
    /// wiring `continuation.onTermination`.
    func runGreedyFastPath(
        requestId id: String,
        container: ModelContainer,
        promptTokens: [Int],
        maxTokens: Int,
        continuation: AsyncStream<GenerationEvent>.Continuation
    ) {
        let scheduler = self
        let promptCount = promptTokens.count
        let task = Task {
            // Token-only input (no media). `MLXArray(promptTokens)` is a cheap
            // host-side copy; the GPU work happens inside `generate`.
            let lmInput = LMInput(tokens: MLXArray(promptTokens))
            // temperature 0 ⇒ ArgMaxSampler. topP/topK/penalties left at their
            // defaults are inert under greedy. maxTokens bounds the decode.
            let params = GenerateParameters(maxTokens: maxTokens, temperature: 0)

            // Admission ≈ now: prefill is about to begin. Drives the
            // pending-timeout predicate and starts the prefill-EWMA window.
            await scheduler.recordAdmission(requestId: id, at: .now)

            let genStream: AsyncStream<Generation>
            do {
                genStream = try await container.generate(input: lmInput, parameters: params)
            } catch {
                _ = await scheduler.recordFinish(
                    requestId: id, promptTokens: promptCount,
                    completionTokens: 0, success: false)
                continuation.yield(.error(
                    "fast path generation failed: \(error.localizedDescription)"))
                continuation.finish()
                await scheduler.clearFastPathTask(id)
                return
            }

            var sawFirstToken = false
            var completionTokens = 0
            var reportedPrompt = promptCount

            for await gen in genStream {
                // Cooperative cancellation: a client cancel / model reload cancels
                // this task; break and let the finish bookkeeping below run.
                if Task.isCancelled { break }
                switch gen {
                case .chunk(let text):
                    if !sawFirstToken {
                        sawFirstToken = true
                        await scheduler.recordFirstToken(requestId: id, at: .now)
                    }
                    if !text.isEmpty {
                        continuation.yield(.chunk(text))
                    }
                case .info(let info):
                    reportedPrompt = info.promptTokenCount
                    completionTokens = info.generationTokenCount
                case .toolCall:
                    // Tool-call parsing is handled upstream on the raw text by
                    // the consumer (`MultiModelBatchSchedulerEngine`). The
                    // single-sequence generator only surfaces this when it parsed
                    // a call from the text it already emitted as `.chunk`s, so we
                    // ignore it to stay text-stream compatible with the engine
                    // path (which emits raw text and never `.toolCall`).
                    break
                }
            }

            let cancelled = Task.isCancelled
            // Reuse the engine bridge's finish bookkeeping: removes the bridge,
            // updates the decode + prefill EWMA, releases the KV reservation, and
            // returns billing-safe usage counts (max of observed vs. terminal).
            let usage = await scheduler.recordFinish(
                requestId: id,
                promptTokens: reportedPrompt,
                completionTokens: completionTokens,
                success: !cancelled)

            if cancelled {
                // Emit delivered usage (so a listener can bill partial work)
                // before the cancellation error, mirroring the engine bridge.
                if usage.promptTokens > 0 || usage.completionTokens > 0 {
                    continuation.yield(.info(
                        promptTokens: usage.promptTokens,
                        completionTokens: usage.completionTokens,
                        tokensPerSecond: usage.tps))
                }
                continuation.yield(.error("request cancelled"))
            } else {
                continuation.yield(.info(
                    promptTokens: usage.promptTokens,
                    completionTokens: usage.completionTokens,
                    tokensPerSecond: usage.tps))
            }
            continuation.finish()
            await scheduler.clearFastPathTask(id)
        }
        fastPathTasks[id] = task
    }

    // MARK: - Task tracking / teardown

    /// Remove a finished fast-path task handle. Called by the task itself on
    /// completion. Safe for an unknown id.
    func clearFastPathTask(_ id: String) {
        fastPathTasks.removeValue(forKey: id)
    }

    /// Cancel the in-flight fast-path task for `id`, if any. Returns true when a
    /// task existed and was cancelled. The task observes `Task.isCancelled`,
    /// runs its finish bookkeeping (KV release, bridge removal, terminal events)
    /// and clears its own handle.
    @discardableResult
    func cancelFastPathTask(_ id: String) -> Bool {
        guard let task = fastPathTasks[id] else { return false }
        task.cancel()
        return true
    }

    /// Cancel every in-flight fast-path task (model reload / `cancelAll`). Each
    /// task self-removes; callers that also clear `fastPathTasks` (e.g.
    /// `stopCurrentEngine`) make late `clearFastPathTask` calls harmless no-ops.
    func cancelAllFastPathTasks() {
        for task in fastPathTasks.values { task.cancel() }
    }
}

// MARK: - Test support
//
// Internal + `@testable`-only; dead-code-stripped from production binaries.

extension BatchScheduler {
    /// Force the B=1 fast-path enablement gate on/off, bypassing the env flags.
    /// `nil` restores env-driven behavior. Lets a benchmark A/B the fast path vs.
    /// the batched engine in a single process (mutating `ProcessInfo`'s cached
    /// environment mid-run is unreliable).
    func _setForceB1FastPathForTest(_ value: Bool?) {
        _forceB1FastPathForTest = value
    }

    /// Test accessor: number of in-flight fast-path tasks currently tracked.
    func _fastPathTaskCountForTest() -> Int { fastPathTasks.count }
}
