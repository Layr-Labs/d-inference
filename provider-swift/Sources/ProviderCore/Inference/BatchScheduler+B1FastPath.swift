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
//   * ON by default; opt OUT with an env flag (`DARKBLOOM_B1_GREEDY_FAST_PATH=0`
//     or `DARKBLOOM_GEMMA_B1_FAST_PATH=0`).
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

    /// Whether the B=1 greedy fast path is enabled. **Default ON.** Two flags are
    /// accepted as an opt-OUT: `DARKBLOOM_B1_GREEDY_FAST_PATH` (generic) and
    /// `DARKBLOOM_GEMMA_B1_FAST_PATH` (Gemma-targeted alias). Set EITHER to
    /// `"0"`/`"false"`/`"no"`/`"off"` to disable; any other (or absent) value
    /// keeps it on. Read per-call (cheap) so tests / operators can toggle it via
    /// the environment without restarting the scheduler.
    ///
    /// (Still only ENGAGES for requests that pass every conservative eligibility
    /// gate in `b1FastPathEligiblePure` — Gemma-family, greedy, no KV quant, no
    /// tools, in-context, single exclusive in-flight request. Anything else
    /// defers to the batched engine regardless of this flag.)
    static func b1GreedyFastPathEnabled() -> Bool {
        let env = ProcessInfo.processInfo.environment
        let off: Set<String> = ["0", "false", "no", "off"]
        if let v = env["DARKBLOOM_B1_GREEDY_FAST_PATH"], off.contains(v.lowercased()) {
            return false
        }
        if let v = env["DARKBLOOM_GEMMA_B1_FAST_PATH"], off.contains(v.lowercased()) {
            return false
        }
        return true
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
        promptTokenCount: Int,
        maxTokens: Int,
        cacheScope: String,
        allowFastPath: Bool
    ) -> Bool {
        Self.b1FastPathEligiblePure(
            // Test override wins when set; otherwise consult the env flags.
            enabled: _forceB1FastPathForTest ?? Self.b1GreedyFastPathEnabled(),
            allowFastPath: allowFastPath,
            modelId: modelId,
            kvQuantEnabled: kvQuantEnabled,
            temperature: temperature,
            topP: topP,
            topK: topK,
            seed: seed,
            promptTokenCount: promptTokenCount,
            maxTokens: maxTokens,
            maxContextLength: maxContextLength,
            cacheScope: cacheScope,
            // Prefix/checkpoint cache active for this model (checkpoint tier for
            // Gemma-4/GPT-OSS, engine tier for pure-attention models). When on, an
            // unscoped request must stay on the engine so cache stores/hits keep
            // working — the fast path bypasses planRestoredCheckpoint/capture.
            prefixCacheEnabled: checkpointManager != nil || enginePrefixCacheActive,
            activeBridgeCount: activeBridges.count,
            pendingRequestCount: pendingRequestCount,
            fastPathActive: !fastPathTasks.isEmpty,
            hasContainer: modelContainer != nil
        )
    }

    /// Pure eligibility policy for the B=1 greedy fast path. No actor state — all
    /// inputs are parameters — so it is fully unit-testable. Order is irrelevant
    /// to the result (all conditions must hold), but kept cheapest-first.
    static func b1FastPathEligiblePure(
        enabled: Bool,
        allowFastPath: Bool,
        modelId: String,
        kvQuantEnabled: Bool,
        temperature: Float,
        topP: Float?,
        topK: Int?,
        seed: UInt64?,
        promptTokenCount: Int,
        maxTokens: Int,
        maxContextLength: Int,
        cacheScope: String,
        prefixCacheEnabled: Bool,
        activeBridgeCount: Int,
        pendingRequestCount: Int,
        fastPathActive: Bool,
        hasContainer: Bool
    ) -> Bool {
        guard enabled else { return false }
        // Caller opt-in. The engine consumer clears this for tool-bearing
        // requests: the fast path is greedy text-only and cannot reproduce the
        // engine's raw-text tool-call contract (`container.generate` may parse a
        // call into a `.toolCall` event, CONSUMING the text — see the runner's
        // `.toolCall` handling), so tool requests must stay on the engine path.
        guard allowFastPath else { return false }
        // Family gate: only Gemma-4 is profiled + validated for this bypass, and
        // its greedy / EOS behavior is only known-good there. Every other family
        // (different EOS sets, tool/stop conventions) defers to the batched engine.
        guard modelId.lowercased().contains("gemma") else { return false }
        // KV quantization: batched-engine admission reserves at the REDUCED
        // (quantized) per-token KV rate, but `ModelContainer.generate` allocates a
        // full fp16 KV cache. A fast-path reservation sized at the quantized rate
        // would under-count ~2x and risk a unified-memory OOM, so whenever KV
        // quant is active we defer to the engine (which owns the quantized cache).
        guard !kvQuantEnabled else { return false }
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
        // Need a real prompt to prefill (a 0-token prompt has no greedy seed).
        guard promptTokenCount > 0 else { return false }
        // Context window: the fast path runs a cold prefill of the WHOLE prompt
        // and decodes up to `maxTokens` against one fresh cache. If that span
        // exceeds the model's context window, defer to the engine path — it
        // enforces context limits and emits the precise context-overflow
        // rejection. `maxContextLength == 0` ⇒ context unknown ⇒ skip this gate
        // (the remaining gates, incl. the token-budget guard upstream, still apply).
        if maxContextLength > 0 {
            guard promptTokenCount + maxTokens <= maxContextLength else { return false }
        }
        // No prefix-cache scope: the fast path runs a cold prefill against a
        // fresh cache and does not participate in the checkpoint / engine prefix
        // tiers, so a scoped request keeps the engine path to retain cache reuse.
        guard cacheScope.isEmpty else { return false }
        // Prefix/checkpoint cache enabled: even an UNSCOPED greedy request would
        // normally populate/hit the checkpoint (or engine-tier) prefix cache via
        // `planRestoredCheckpoint` / `finalizeRestore` + the engine capture hooks.
        // The fast path bypasses all of that (cold prefill on a fresh cache), so
        // when a prefix cache is active (the provider default) we defer to the
        // engine — otherwise default-on would silently stop populating/serving the
        // cache for the common unscoped path (and break the HybridCheckpoint
        // live tests that assert stores/hits).
        guard !prefixCacheEnabled else { return false }
        // Exclusive: no other in-flight or queued work. Concurrent batched work
        // would defeat the single-row assumption (shared GPU + KV headroom).
        guard activeBridgeCount == 0 else { return false }
        guard pendingRequestCount == 0 else { return false }
        // And no OTHER fast-path task already running (explicit single-row gate;
        // belt-and-suspenders with the activeBridgeCount check, since a running
        // fast path also holds a bridge).
        guard !fastPathActive else { return false }
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
    /// ONLY the B=1 Gemma greedy fast path uses this runner (temperature 0,
    /// no seed — `b1FastPathEligiblePure` requires both). The sequential-
    /// serving route (DeepSeek-V4) uses `runSequentialRawTextPath` instead —
    /// see `BatchScheduler+SequentialRawRunner.swift` for why: this runner's
    /// `ModelContainer.generate` attaches a tool-call parser that can consume
    /// generated text into a `.toolCall` event, which is unsafe for that
    /// route regardless of whether the request carries tools.
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
            // Greedy only: temperature 0 ⇒ ArgMaxSampler; topP/topK/penalties
            // left at their defaults are inert under greedy. No seed — the
            // eligibility gate rejects any request that supplies one.
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
            // Count every streamed chunk as >= 1 completion token. The terminal
            // `.info` carries the EXACT generation count, but it only arrives on a
            // clean finish; on cancellation the loop breaks before it, so without
            // this running tally `recordFinish` would settle at 0 completion tokens
            // and the coordinator would bill $0 for work already streamed to the
            // client. `recordFinish` takes max(observed, terminal), so a clean
            // finish still uses the exact `.info` count (>= the chunk tally).
            var streamedTokens = 0
            var terminalCompletion: Int? = nil
            var reportedPrompt = promptCount
            // Defensive: the greedy text-only fast path should never see a parsed
            // tool call (tool requests are kept on the engine path by the caller's
            // `allowFastPath` gate). If one is surfaced anyway we cannot faithfully
            // reproduce the engine's raw-text behavior, so we FAIL rather than drop.
            var sawToolCall = false

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
                    streamedTokens += 1
                    if !text.isEmpty {
                        continuation.yield(.chunk(text))
                    }
                case .info(let info):
                    reportedPrompt = info.promptTokenCount
                    terminalCompletion = info.generationTokenCount
                case .toolCall:
                    // `container.generate` parsed a tool call (and may have
                    // CONSUMED its text rather than emitting it as `.chunk`s).
                    // Silently dropping it would lose the call; the engine path
                    // emits raw text and never `.toolCall`, so we cannot match it
                    // here. Mark failure and stop.
                    sawToolCall = true
                }
                if sawToolCall { break }
            }

            let cancelled = Task.isCancelled
            // Billing-safe completion count: terminal exact count when present,
            // otherwise the streamed-chunk lower bound (covers cancel + tool-call
            // failure, where no `.info` arrived).
            let completionTokens = max(terminalCompletion ?? 0, streamedTokens)
            let succeeded = !cancelled && !sawToolCall
            // Reuse the engine bridge's finish bookkeeping: removes the bridge,
            // updates the decode + prefill EWMA, releases the KV reservation, and
            // returns billing-safe usage counts (max of observed vs. terminal).
            let usage = await scheduler.recordFinish(
                requestId: id,
                promptTokens: reportedPrompt,
                completionTokens: completionTokens,
                success: succeeded)

            // Emit delivered usage (so a listener can bill partial work) before
            // any terminal error, mirroring the engine bridge.
            if !succeeded, usage.promptTokens > 0 || usage.completionTokens > 0 {
                continuation.yield(.info(
                    promptTokens: usage.promptTokens,
                    completionTokens: usage.completionTokens,
                    tokensPerSecond: usage.tps,
                    finishReason: nil))
            }
            if cancelled {
                continuation.yield(.error("request cancelled"))
            } else if sawToolCall {
                continuation.yield(.error(
                    "fast path does not support tool calls; please retry"))
            } else {
                // `container.generate` stops at maxTokens without surfacing a
                // reason; a decode that used the full budget is a truncation
                // (finish_reason "length"), matching the engine paths.
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
        // Defensive: also drop any in-progress admission fence (a `submitTokenized`
        // suspended at its KV-reserve await). Its own exit will also clear this.
        fastPathAdmitting = false
        for task in fastPathTasks.values { task.cancel() }
    }

    /// Cancel AND fence every in-flight fast-path task — used by
    /// `stopCurrentEngine` before it nil's `modelContainer` and clears the MLX
    /// cache. Unlike the engine (which is fenced by `stopAndWait`), a fast-path
    /// task runs off-engine inside `ModelContainer.generate`, holding and running
    /// GPU work against the model + its KV cache. If teardown freed that state
    /// while a task were still mid-`generate`, it could touch released model/MLX
    /// state. Awaiting each task's value blocks until it has observed
    /// cancellation, run its finish bookkeeping (KV release + bridge removal +
    /// terminal events) and dropped its model/iterator references.
    ///
    /// The handles are snapshotted first so a self-removing `clearFastPathTask`
    /// during the awaits cannot mutate the collection being iterated. The await
    /// suspends the actor so those actor-isolated callbacks make progress; no NEW
    /// fast path can start meanwhile because `stopCurrentEngine` has already
    /// nil'd `engine` (every submit path short-circuits on a nil engine).
    /// Idempotent: a no-op when nothing is in flight.
    func waitForFastPathTasks() async {
        // Clear the admission fence first (before the early-return guard) so a
        // `submitTokenized` suspended mid-admission can't leave it stuck set after
        // teardown. `stopCurrentEngine` has already nil'd `engine`, so no new fast
        // path can begin.
        fastPathAdmitting = false
        let inflight = Array(fastPathTasks.values)
        guard !inflight.isEmpty else { return }
        for task in inflight { task.cancel() }
        for task in inflight { await task.value }
        fastPathTasks.removeAll()
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

    /// Force the sequential-serving flag without loading a model, so tests can
    /// pin the single-slot heartbeat clamp (`effectiveMaxConcurrentRequests`).
    func _setRequiresSequentialServingForTest(_ value: Bool) {
        requiresSequentialServing = value
    }

    /// Force `expertStreamingConfigured` without a full `loadModel(container:)`
    /// call (which needs a real, loaded `ModelContainer`), so tests can pin
    /// the "did this load configure MoE expert streaming" flag and exercise
    /// `stopCurrentEngine()`'s purge-on-unload decision in isolation.
    func _setExpertStreamingConfiguredForTest(_ value: Bool) {
        expertStreamingConfigured = value
    }

    /// Test accessor for `expertStreamingConfigured`.
    func _expertStreamingConfiguredForTest() -> Bool { expertStreamingConfigured }
}
