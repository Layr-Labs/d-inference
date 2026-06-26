// Copyright © 2026 Eigen Labs.
//
// BatchScheduler request submission + cancellation: tokenized + raw submit
// paths (admission, reservation, bridge start), pool reclaim, cancel/cancelAll.

import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import ProviderCoreFoundation
import os

extension BatchScheduler {
    // MARK: - Submit / cancel

    /// The scheduler token gate (`tokenBudgetMax`) counts MLX's reclaimable pool as
    /// used, so a request can be rejected with `token_budget_exhausted` even though
    /// flushing that pool would admit it — and that gate runs before the per-request
    /// KV reservation (which has its own self-heal). Flush once here when the gate is
    /// tight (rate-limited + shortfall-gated, sharing the reservation gate's limiter)
    /// so the gate is re-evaluated against the reclaimed headroom. Call this BEFORE
    /// reading `activeTokenBudgetUsed`, so its only suspension is outside the atomic
    /// activeUsed→bridge section the cumulative gate relies on.
    private func reclaimPoolForTokenBudget(requestBudget: Int) async {
        guard kvBytesPerToken > 0, let kvBudget else { return }
        let need = activeTokenBudgetUsed + requestBudget
        guard need > tokenBudgetMax else { return }
        let shortfallBytes = UInt64(need - tokenBudgetMax) * UInt64(kvBytesPerToken)
        // Fire-and-forget signal (nonisolated — no actor hop, no GPU wait). The
        // flush runs off the budget actor; `tokenBudgetMax` is re-read below
        // against the current snapshot (a near-miss may reject — acceptable; the
        // background reclaim and proactive sweep keep the pool small so most
        // admits succeed without ever near-missing).
        kvBudget.reclaimForShortfall(shortfallBytes)
    }

    /// Submit a pre-tokenized prompt. Used by `MultiModelBatchSchedulerEngine`
    /// which tokenizes the full OpenAI request (including tools, tool_call_id,
    /// reasoning_content, etc.) itself, then hands the token IDs here.
    ///
    /// This bypasses the lossy `ChatMessage → applyChatTemplate` path in the
    /// `ChatCompletionRequest` overload, which drops tool-related fields.
    public func submitTokenized(
        promptTokens: [Int],
        maxTokens: Int,
        temperature: Float = 0.0,
        topP: Float? = nil,
        topK: Int? = nil,
        seed: UInt64? = nil,
        requestId: String? = nil,
        cacheScope: String = ""
    ) async -> AsyncStream<GenerationEvent> {
        let id = requestId ?? "req-\(UUID().uuidString.prefix(12))"
        let (stream, continuation) = AsyncStream<GenerationEvent>.makeStream()

        guard let engine = self.engine else {
            continuation.yield(.error("No model loaded"))
            continuation.finish()
            return stream
        }
        // Pin the load epoch with the captured engine so we can detect
        // a concurrent unload/reload across the awaits below (planner, KV, restore).
        let submitEpoch = generationEpoch

        let requestBudget = promptTokens.count + maxTokens
        // Flush the reclaimable pool before the token gate if it's tight (the gate
        // counts the pool as used). The await is here, before the atomic
        // activeUsed→bridge section below, so it adds no reentrancy there.
        await reclaimPoolForTokenBudget(requestBudget: requestBudget)
        let budgetMax = tokenBudgetMax
        guard requestBudget <= budgetMax else {
            // Rejected before any bridge exists — record demand for the liveness
            // watchdog (a pinned pool is detectable only via this signal).
            noteAdmissionReject()
            continuation.yield(.error(
                "token_budget_exhausted: request requires \(requestBudget) tokens but only \(budgetMax) available"
            ))
            continuation.finish()
            return stream
        }

        let activeUsed = activeTokenBudgetUsed
        if activeUsed + requestBudget > budgetMax {
            noteAdmissionReject()
            continuation.yield(.error(
                "token_budget_exhausted: request requires \(requestBudget) tokens but only \(budgetMax - activeUsed) available"
            ))
            continuation.finish()
            return stream
        }
        // B=1 greedy fast path eligibility — MUST be decided BEFORE inserting our
        // bridge (it checks `activeBridges.isEmpty` for exclusivity). When taken,
        // this bypasses the batched engine + planner for a single greedy request;
        // otherwise the unchanged batched-engine path below runs.
        let useFastPath = b1FastPathEligible(
            temperature: temperature,
            topP: topP,
            topK: topK,
            seed: seed,
            maxTokens: maxTokens,
            cacheScope: cacheScope
        )
        let bridge = BridgeState(
            requestId: id,
            promptTokens: promptTokens.count,
            maxTokens: maxTokens,
            submittedAt: .now
        )
        activeBridges[id] = bridge

        if useFastPath {
            // Reserve KV bytes (cold; no restore, no planner, no engine enqueue)
            // so the global KV budget and concurrent admissions still account for
            // this request exactly as the engine path would.
            let kvOutcome = await reserveKVForRequest(
                requestId: id,
                requestTokens: requestBudget,
                reservationTokens: requestBudget,
                restorePlanned: false
            )
            guard kvOutcome != .failed else {
                await dropBridge(requestId: id)
                noteAdmissionReject()
                continuation.yield(.error(
                    "token_budget_exhausted: insufficient global KV cache headroom"))
                continuation.finish()
                return stream
            }
            // Re-check the captured engine is still current and the container is
            // live after the reserve await — a reload/unload may have run. Use
            // releaseRequestResources (not bare dropBridge) so the reservation
            // made above is not leaked if a cancel dropped the bridge meanwhile.
            guard engineStillCurrent(submitEpoch, engine), let container = self.modelContainer else {
                await releaseRequestResources(id)
                continuation.yield(.error("model reloaded during submit; please retry"))
                continuation.finish()
                return stream
            }
            runGreedyFastPath(
                requestId: id,
                container: container,
                promptTokens: promptTokens,
                maxTokens: maxTokens,
                continuation: continuation
            )
            let scheduler = self
            continuation.onTermination = { @Sendable termination in
                if case .cancelled = termination {
                    Task { await scheduler.cancel(requestId: id) }
                }
            }
            return stream
        }

        if let planner = self.planner {
            await refreshPlannerPolicy(activeTokenBudget: tokenBudgetMax)
            let result = await planner.admit(
                id: id,
                promptTokenCount: promptTokens.count,
                maxOutputTokens: maxTokens
            )
            if case .rejected(_, let reason) = result {
                await dropBridge(requestId: id)
                continuation.yield(.error(self.rejectionMessage(for: reason, promptTokens: promptTokens.count)))
                continuation.finish()
                return stream
            }
            await refreshPendingSummaryCache()
        }

        var sp = SamplingParams(maxTokens: maxTokens, temperature: temperature)
        if let topP { sp.topP = topP }
        if let topK { sp.topK = topK }
        if let seed { sp.seed = seed }

        let req = Request(
            requestId: id,
            prompt: promptTokens as AnyHashable,
            samplingParams: sp
        )
        let plannedRestore = await planRestoredCheckpoint(
            promptTokens: promptTokens,
            scope: cacheScope,
            maxTokens: maxTokens
        )
        let acceptedRestore = acceptRestoredCheckpointBudget(
            requestId: id,
            requestTokens: requestBudget,
            admission: plannedRestore
        )
        let kvReservationTokens = acceptedRestore?.reservedTokens ?? requestBudget
        let kvOutcome = await reserveKVForRequest(
            requestId: id,
            requestTokens: requestBudget,
            reservationTokens: kvReservationTokens,
            restorePlanned: acceptedRestore != nil
        )
        guard kvOutcome != .failed else {
            await dropBridge(requestId: id)
            // The per-request KV reservation failed (collapsed headroom): the
            // bridge is dropped, so this too returns with no active entry. Record
            // demand for the liveness watchdog.
            noteAdmissionReject()
            continuation.yield(.error("token_budget_exhausted: insufficient global KV cache headroom"))
            continuation.finish()
            return stream
        }
        // Materialize the restore ONLY when its restore-sized reservation is held
        // (`.restoreReserved`). On `.coldReserved` the reserve downgraded a planned
        // restore (or none was planned): only the cold reservation is held, so
        // attaching restore-sized KV here would under-reserve and OOM. The
        // downgrade already cleared bridge.reservedTokens; req.restoredCheckpoint
        // stays nil and the request runs as a cold prefill.
        if kvOutcome == .restoreReserved, let acceptedRestore {
            await finalizeRestore(
                req,
                id: id,
                admission: acceptedRestore,
                promptTokens: promptTokens,
                scope: cacheScope,
                requestBudget: requestBudget
            )
        }
        // Re-check the engine is still the one we captured (a reload/
        // unload may have run during the awaits above). Enqueuing onto a stopped/
        // superseded engine hangs the request or runs it on the wrong model.
        // Use releaseRequestResources (not bare dropBridge): a cancel/timeout
        // could have dropped the bridge during planner.admit BEFORE we reserved
        // KV above, so dropBridge alone would no-op and leak the reservation.
        guard engineStillCurrent(submitEpoch, engine) else {
            await releaseRequestResources(id)
            continuation.yield(.error("model reloaded during submit; please retry"))
            continuation.finish()
            return stream
        }
        _ = await engine.core.addRequest(req)
        // The add is now registered (addRequest's continuation only
        // resumes after its engineQueue block ran). Re-confirm currency; if a stop
        // interleaved across the add, abort it so it doesn't hang on a stopped
        // scheduler that abortAllRequests' pre-add snapshot missed.
        guard await confirmEnqueuedOrAbort(
            requestId: id, capturedEpoch: submitEpoch, capturedEngine: engine
        ) else {
            continuation.yield(.error("model reloaded during submit; please retry"))
            continuation.finish()
            return stream
        }

        runBridge(
            requestId: id,
            outputStream: engine.core.streamOutputs(requestId: id),
            continuation: continuation
        )

        let scheduler = self
        continuation.onTermination = { @Sendable termination in
            if case .cancelled = termination {
                Task { await scheduler.cancel(requestId: id) }
            }
        }

        return stream
    }

    public func submit(
        request: ChatCompletionRequest,
        requestId: String? = nil
    ) async -> AsyncStream<GenerationEvent> {
        let id = requestId ?? "req-\(UUID().uuidString.prefix(12))"
        let (stream, continuation) = AsyncStream<GenerationEvent>.makeStream()

        guard let engine = self.engine, let tk = tokenizer else {
            continuation.yield(.error("No model loaded"))
            continuation.finish()
            return stream
        }
        // Pin the load epoch with the captured engine (see submitTokenized).
        let submitEpoch = generationEpoch

        // Pre-tokenize so chat-template errors surface as `.error` events;
        // engine's internal `buildPrompt` silently falls back to role:content.
        let messages: [[String: any Sendable]] = request.messages.map { msg in
            [
                "role": msg.role,
                "content": msg.role == "assistant"
                    ? stripHarmonyChannelFraming(fromAssistantContent: msg.content)
                    : msg.content,
            ]
        }
        let promptTokens: [Int]
        do {
            promptTokens = try tk.inner.applyChatTemplate(
                messages: messages, tools: nil, additionalContext: nil
            )
        } catch {
            continuation.yield(.error("Failed to tokenize: \(error.localizedDescription)"))
            continuation.finish()
            return stream
        }

        let maxTokens = Self.resolvedMaxTokens(
            requested: request.max_tokens, defaultMaxTokens: defaultMaxTokens
        )

        let requestBudget = promptTokens.count + maxTokens
        // Flush the reclaimable pool before the token gate if it's tight (the gate
        // counts the pool as used). This await is intentionally before the atomic
        // activeUsed→bridge section below, so it adds no reentrancy there.
        await reclaimPoolForTokenBudget(requestBudget: requestBudget)
        let budgetMax = tokenBudgetMax
        guard requestBudget <= budgetMax else {
            // Rejected before any bridge exists — record demand for the liveness
            // watchdog (a pinned pool is detectable only via this signal).
            noteAdmissionReject()
            continuation.yield(.error(
                "token_budget_exhausted: request requires \(requestBudget) tokens but only \(budgetMax) available"
            ))
            continuation.finish()
            return stream
        }

        // Atomic: the cumulative gate + slot reservation must
        // run in one synchronous block. Actor reentrancy across the
        // upcoming `planner.admit` / `kvBudget.reserve` awaits would
        // otherwise let two concurrent submits both read the same
        // `activeTokenBudgetUsed` and both pass the check.
        //
        // Reserve our slot by inserting the bridge into `activeBridges`
        // BEFORE the first await. Other interleaving submits will see
        // this request's budget in `activeTokenBudgetUsed`. Any early
        // exit below (planner reject, KV reject) must roll back the
        // bridge via `dropBridge(...)`.
        let activeUsed = activeTokenBudgetUsed
        if activeUsed + requestBudget > budgetMax {
            noteAdmissionReject()
            continuation.yield(.error(
                "token_budget_exhausted: request requires \(requestBudget) tokens but only \(budgetMax - activeUsed) available"
            ))
            continuation.finish()
            return stream
        }
        let bridge = BridgeState(
            requestId: id,
            promptTokens: promptTokens.count,
            maxTokens: maxTokens,
            submittedAt: .now
        )
        activeBridges[id] = bridge

        if let planner = self.planner {
            await refreshPlannerPolicy(activeTokenBudget: tokenBudgetMax)
            let result = await planner.admit(
                id: id,
                promptTokenCount: promptTokens.count,
                maxOutputTokens: maxTokens
            )
            if case .rejected(_, let reason) = result {
                await dropBridge(requestId: id)
                continuation.yield(.error(self.rejectionMessage(for: reason, promptTokens: promptTokens.count)))
                continuation.finish()
                return stream
            }
            await refreshPendingSummaryCache()
        }

        // Greedy (temperature == 0) hits the engine's vectorized argmax
        // fast path automatically; just pass the requested value through.
        let temperature = request.temperature ?? 0.0
        var sp = SamplingParams(maxTokens: maxTokens, temperature: temperature)
        if let topP = request.top_p { sp.topP = topP }
        if let topK = request.top_k { sp.topK = topK }
        if let seed = request.seed { sp.seed = seed }

        let req = Request(
            requestId: id,
            prompt: promptTokens as AnyHashable,
            samplingParams: sp
        )
        let plannedRestore = await planRestoredCheckpoint(
            promptTokens: promptTokens,
            scope: request.cacheScope,
            maxTokens: maxTokens
        )
        let acceptedRestore = acceptRestoredCheckpointBudget(
            requestId: id,
            requestTokens: requestBudget,
            admission: plannedRestore
        )
        let kvReservationTokens = acceptedRestore?.reservedTokens ?? requestBudget
        let kvOutcome = await reserveKVForRequest(
            requestId: id,
            requestTokens: requestBudget,
            reservationTokens: kvReservationTokens,
            restorePlanned: acceptedRestore != nil
        )
        guard kvOutcome != .failed else {
            await dropBridge(requestId: id)
            // The per-request KV reservation failed (collapsed headroom): the
            // bridge is dropped, so this too returns with no active entry. Record
            // demand for the liveness watchdog.
            noteAdmissionReject()
            continuation.yield(.error("token_budget_exhausted: insufficient global KV cache headroom"))
            continuation.finish()
            return stream
        }
        // Materialize the restore ONLY when its restore-sized reservation is held
        // (`.restoreReserved`). On `.coldReserved` the reserve downgraded a planned
        // restore (or none was planned): only the cold reservation is held, so
        // attaching restore-sized KV here would under-reserve and OOM. The
        // downgrade already cleared bridge.reservedTokens; req.restoredCheckpoint
        // stays nil and the request runs as a cold prefill.
        if kvOutcome == .restoreReserved, let acceptedRestore {
            await finalizeRestore(
                req,
                id: id,
                admission: acceptedRestore,
                promptTokens: promptTokens,
                scope: request.cacheScope,
                requestBudget: requestBudget
            )
        }
        // Re-check the captured engine is still current after the awaits.
        // releaseRequestResources (not bare dropBridge): a cancel/timeout during
        // planner.admit could have dropped the bridge BEFORE we reserved KV, so
        // dropBridge alone would no-op and leak the reservation made above.
        guard engineStillCurrent(submitEpoch, engine) else {
            await releaseRequestResources(id)
            continuation.yield(.error("model reloaded during submit; please retry"))
            continuation.finish()
            return stream
        }
        _ = await engine.core.addRequest(req)
        // Re-confirm currency AFTER the add registered (see
        // submitTokenized); abort the just-added request if a stop interleaved.
        guard await confirmEnqueuedOrAbort(
            requestId: id, capturedEpoch: submitEpoch, capturedEngine: engine
        ) else {
            continuation.yield(.error("model reloaded during submit; please retry"))
            continuation.finish()
            return stream
        }

        // Hand the per-request stream to the bridge extension. Bridge
        // teardown / finish-event mapping all live in
        // `BatchScheduler+EngineBridge.swift`.
        runBridge(
            requestId: id,
            outputStream: engine.core.streamOutputs(requestId: id),
            continuation: continuation
        )

        let scheduler = self
        continuation.onTermination = { @Sendable termination in
            if case .cancelled = termination {
                Task { await scheduler.cancel(requestId: id) }
            }
        }

        return stream
    }

    public func cancel(requestId: String) async {
        // B=1 fast-path request: it runs off-engine, so the engine abort below
        // can't reach it. Cancel its task; the task observes the cancellation,
        // runs its own finish bookkeeping (KV release + bridge removal + terminal
        // events) and clears its handle. (If it already finished and self-removed,
        // this is a no-op and we fall through to the harmless engine/local path.)
        if cancelFastPathTask(requestId) {
            return
        }
        if let engine = self.engine {
            // Engine delivers a terminal RequestOutput synchronously; the
            // streaming Task handles `recordFinish` + KV release.
            //
            // AbortRequest returns false when the engine has no
            // collector for this id yet — i.e. the request is in `activeBridges`
            // but not yet registered with EngineCore (still mid-submit awaiting
            // planner/KV/restore, or its `addRequest` engineQueue block hasn't
            // run). In that window the engine abort is a no-op, so the streaming
            // Task will never see a terminal output and our local bridge/planner/
            // KV state would leak. Fall through to drop it locally. (If the add
            // later lands, the orphaned request is removed from `activeBridges`,
            // so its terminal output is a harmless no-op on recordFinish/release.)
            if engine.core.abortRequest(requestId) {
                return
            }
        }
        // No engine, or the engine had no in-flight collector for this id:
        // tear down whatever local state exists (planner-pending and/or a
        // not-yet-registered bridge). dropBridge releases the KV reservation +
        // cancels the planner entry; the explicit calls below cover the
        // engine-nil path where no bridge was created.
        await dropBridge(requestId: requestId)
        if let planner = self.planner {
            await planner.cancel(requestID: requestId)
            await refreshPendingSummaryCache()
        }
        await releaseKVReservation(requestID: requestId)
    }

    public func cancelAll() async {
        // Cancel any off-engine B=1 fast-path tasks first; each self-removes and
        // releases its KV/bridge. The bridge-id KV release + removeAll below then
        // covers the engine-path bridges (and is an idempotent no-op for any
        // fast-path bridge a racing task already tore down).
        cancelAllFastPathTasks()
        if let engine = self.engine {
            _ = engine.core.abortAllRequests()
        }
        // Planner pending queue: engine only knows about admitted requests.
        if let planner = self.planner {
            let snapshot = await planner.snapshot()
            for entry in snapshot.pendingRequests {
                await planner.cancel(requestID: entry.id)
            }
            for entry in snapshot.activeRequests {
                await planner.cancel(requestID: entry.id)
            }
            await refreshPendingSummaryCache()
        }
        let bridgeIds = Array(activeBridges.keys)
        for id in bridgeIds {
            await releaseKVReservation(requestID: id)
        }
        activeBridges.removeAll()
        timedOutBridges.removeAll()
    }

    // P1: disambiguate a batch-token-budget rejection so the coordinator never has
    // to guess deterministic-vs-transient from a stale heartbeat. maxTokensPerBatch
    // is min(context, activeTokenBudget), so "exceeds batch token budget" conflates
    // two very different cases: prompt > model context (DETERMINISTIC — every
    // provider rejects identically) vs prompt > this node's pressure-shrunk KV
    // budget (TRANSIENT — a bigger/idler box can serve). When the prompt alone
    // exceeds the model context we emit a CONTEXT-overflow message, which the
    // coordinator's classifyRejection already treats as fleet-wide deterministic
    // (stop on the first attempt) rather than failing over. All other reasons keep
    // their canonical string.
    private func rejectionMessage(for reason: BatchRejectionReason, promptTokens: Int) -> String {
        if reason == .requestExceedsBatchTokenBudget,
            maxContextLength > 0,
            promptTokens > maxContextLength
        {
            return "token_budget_exhausted: request exceeds model context window "
                + "(\(promptTokens) prompt tokens > \(maxContextLength) context)"
        }
        return Self.errorMessage(for: reason)
    }

}
