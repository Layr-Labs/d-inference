// Copyright © 2026 Eigen Labs.
//
// Per-request streaming bridge: consumes `engine.core.streamOutputs`
// for one request and yields `GenerationEvent`s on the public
// `AsyncStream`.
//
// All bookkeeping mutations live as `BatchScheduler` actor methods in
// this file so the cross-file `Task { ... }` (started in `submit`) can
// hop onto the actor's executor to update `activeBridges` / EWMA /
// planner state.
//
// Access promotions vs the pre-split file:
//   * `recordAdmission`, `recordFirstToken`, `recordFinish`,
//     `dropBridge`, `consumeTimedOutFlag` were `fileprivate` — they
//     stay `fileprivate` in spirit but compile as `internal` because
//     the bridge Task lives in this extension file (and the symbols
//     are also called from `cancel` paths in the main file).
//   * `recordProgress` is new (in-flight decode visibility).

import Foundation
import MLXLMCommon

extension BatchScheduler {

    // MARK: - Bridge runner (called from `submit` in the main file)

    /// Spin up the per-request stream consumer that translates
    /// `RequestOutput`s into `GenerationEvent`s on `continuation`.
    /// Owns lifecycle: removes the bridge from `activeBridges` on
    /// terminal output, drops it on stream-closed-without-terminal,
    /// and registers an `onTermination` cancellation hook.
    func runBridge(
        requestId id: String,
        outputStream: AsyncStream<RequestOutput>,
        continuation: AsyncStream<GenerationEvent>.Continuation
    ) {
        let scheduler = self
        Task { [continuation] in
            var sawAdmission = false
            var sawFirstToken = false
            var sawTerminal = false
            for await output in outputStream {
                // First `RequestOutput` (even prefill-only with no tokens)
                // marks engine admission. Required by `expirePlannerTimeouts`
                // to distinguish "queued" from "running" — long prefills
                // emit no decoded token for many seconds.
                if !sawAdmission {
                    await scheduler.recordAdmission(requestId: id, at: .now)
                    sawAdmission = true
                }

                // Key first-token on TOKEN count, not `newText`: some
                // tokens (BPE intermediates, specials) decode to empty
                // strings and would otherwise leave `firstTokenAt` nil.
                let hasNewToken = !output.newTokenIds.isEmpty
                    || output.completionTokens > 0
                if !sawFirstToken, hasNewToken {
                    await scheduler.recordFirstToken(requestId: id, at: .now)
                    sawFirstToken = true
                }

                // keep `BridgeState.completionTokens` live so
                // `backendCapacity()` (heartbeats) reports in-flight
                // decode progress, not stale zeros until finish.
                if output.completionTokens > 0 || output.promptTokens > 0 {
                    await scheduler.recordProgress(
                        requestId: id,
                        promptTokens: output.promptTokens,
                        completionTokens: output.completionTokens
                    )
                }

                if !output.newText.isEmpty {
                    continuation.yield(.chunk(output.newText))
                }

                if output.finished || output.error != nil {
                    sawTerminal = true
                    // Three terminal flavors:
                    //   abort               → cancellation (timeout vs cancel)
                    //   error+not-abort     → engine/runtime failure (surface it)
                    //   stop/length/nil err → normal finish (.info)
                    let isAbort = output.finishReason == "abort"
                    let engineError = !isAbort ? output.error : nil
                    if isAbort || engineError != nil {
                        let usage = await scheduler.recordFinish(
                            requestId: id,
                            promptTokens: output.promptTokens,
                            completionTokens: output.completionTokens,
                            success: false
                        )
                        if let err = engineError {
                            // Real engine failure; preserve the message
                            // so callers can report it / decide retry.
                            continuation.yield(.error(err))
                        } else {
                            // An abort did real work — emit its usage before the
                            // error so a listener can still bill delivered tokens.
                            if usage.promptTokens > 0 || usage.completionTokens > 0 {
                                continuation.yield(.info(
                                    promptTokens: usage.promptTokens,
                                    completionTokens: usage.completionTokens,
                                    tokensPerSecond: usage.tps
                                ))
                            }
                            // Distinct pending-timeout vs. client-cancel
                            // string so operators can tell capacity
                            // exhaustion apart from a closed connection.
                            let timedOut = await scheduler.consumeTimedOutFlag(id)
                            if timedOut {
                                continuation.yield(.error(
                                    "request timed out waiting for capacity"))
                            } else {
                                continuation.yield(.error("request cancelled"))
                            }
                        }
                    } else {
                        let usage = await scheduler.recordFinish(
                            requestId: id,
                            promptTokens: output.promptTokens,
                            completionTokens: output.completionTokens,
                            success: true
                        )
                        // Emit the authoritative (max of observed-vs-terminal)
                        // counts from recordFinish, not the raw terminal output
                        // — the terminal can under-report and zero out billing.
                        continuation.yield(.info(
                            promptTokens: usage.promptTokens,
                            completionTokens: usage.completionTokens,
                            tokensPerSecond: usage.tps
                        ))
                    }
                    continuation.finish()
                    return
                }
            }
            // Stream closed without a terminal output (engine torn down
            // mid-request). Surface a distinct error so ProviderLoop does
            // not return a 200-OK with truncated content.
            if !sawTerminal {
                continuation.yield(.error(
                    "request stream closed by engine teardown"))
            }
            await scheduler.dropBridge(requestId: id)
            continuation.finish()
        }
    }

    // MARK: - Bridge bookkeeping (called from the streaming Task)

    /// Set on the first `RequestOutput` seen for a request (engine
    /// picked it up). Drives the pending-timeout predicate so long
    /// prefills are not aborted as queue timeouts.
    func recordAdmission(requestId: String, at instant: ContinuousClock.Instant) {
        guard var bridge = activeBridges[requestId] else { return }
        if bridge.admittedAt == nil {
            bridge.admittedAt = instant
            activeBridges[requestId] = bridge
        }
    }

    func recordFirstToken(requestId: String, at instant: ContinuousClock.Instant) {
        guard var bridge = activeBridges[requestId] else { return }
        bridge.firstTokenAt = instant
        activeBridges[requestId] = bridge
    }

    /// Refresh the bridge's prompt + completion token counts on
    /// every non-empty `RequestOutput` so `backendCapacity()` reports
    /// live in-flight decode (vs. stale 0 until `recordFinish`).
    ///
    /// `output.completionTokens` is cumulative per `OutputCollector`'s
    /// merge semantics; we still `max()` defensively against any
    /// out-of-order delivery.
    func recordProgress(
        requestId: String,
        promptTokens: Int,
        completionTokens: Int
    ) {
        guard var bridge = activeBridges[requestId] else { return }
        bridge.promptTokens = max(bridge.promptTokens, promptTokens)
        bridge.completionTokens = max(bridge.completionTokens, completionTokens)
        activeBridges[requestId] = bridge
    }

    /// Compute TPS, update the EWMA, release budget reservations.
    /// Returns the TPS for the `.info` event.
    func recordFinish(
        requestId: String,
        promptTokens: Int,
        completionTokens: Int,
        success: Bool
    ) async -> (tps: Double, durationSeconds: Double, promptTokens: Int, completionTokens: Int) {
        guard var bridge = activeBridges.removeValue(forKey: requestId) else {
            return (0, 0, 0, 0)
        }
        let finishedAt = ContinuousClock.now
        bridge.lastTokenAt = finishedAt
        // Billing-zero fix: a terminal RequestOutput sometimes reports fewer
        // tokens (often 0) than were already observed streaming via
        // recordProgress. Previously we OVERWROTE the live count with the
        // terminal value, so a completed request could settle at (0,0) — the
        // coordinator then bills $0 and fully refunds. max() means the terminal
        // can only ever raise the count, never zero an observed one.
        bridge.completionTokens = max(bridge.completionTokens, completionTokens)
        bridge.promptTokens = max(bridge.promptTokens, promptTokens)
        let finalCompletion = bridge.completionTokens
        let finalPrompt = bridge.promptTokens

        let tps: Double
        if let firstTokenAt = bridge.firstTokenAt, finalCompletion > 1 {
            let elapsed = finishedAt - firstTokenAt
            let elapsedSeconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            tps = elapsedSeconds > 0
                ? Double(finalCompletion - 1) / elapsedSeconds : 0
        } else {
            let elapsed = finishedAt - bridge.submittedAt
            let elapsedSeconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            tps = elapsedSeconds > 0
                ? Double(finalCompletion) / elapsedSeconds : 0
        }

        if success, tps > 0 {
            // Previously `activeBridges.count + 1` mixed in
            // queued-not-admitted bridges. Use admitted-and-running
            // count (admittedAt != nil) + 1 for the just-finished one.
            let runningRows = activeBridges.values.filter { $0.admittedAt != nil }.count + 1
            updateDecodeTpsEwma(tps: tps)
            recordBatchPerformance(observedBatchSize: max(1, runningRows), tps: tps)
        }

        await releaseKVReservation(requestID: requestId)
        if let planner = self.planner {
            // `cancel` (not `complete`): the planner removes the entry
            // either way, and we don't mark planner-active on admission.
            await planner.cancel(requestID: requestId)
            await refreshPendingSummaryCache()
        }

        let durationSeconds: Double = {
            let elapsed = finishedAt - bridge.submittedAt
            return Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
        }()
        return (tps, durationSeconds, finalPrompt, finalCompletion)
    }

    /// Stream closed without a terminal output (engine torn down
    /// mid-request). Cancel planner reservation and release KV bytes.
    func dropBridge(requestId: String) async {
        if activeBridges.removeValue(forKey: requestId) != nil {
            timedOutBridges.remove(requestId)
            await releaseKVReservation(requestID: requestId)
            if let planner = self.planner {
                await planner.cancel(requestID: requestId)
                await refreshPendingSummaryCache()
            }
        }
    }

    /// Atomically check-and-clear the pending-timeout flag for a bridge.
    /// Returns true iff the bridge was aborted by the pending-timeout
    /// watchdog (vs. a client cancellation).
    func consumeTimedOutFlag(_ id: String) -> Bool {
        return timedOutBridges.remove(id) != nil
    }

    // MARK: - Pending-timeout watchdog

    /// Spawn the detached watchdog Task. Called from `loadModel`.
    /// Cancelled (and re-spawned) on every `stopCurrentEngine` /
    /// `loadModel` cycle.
    func startPendingTimeoutWatchdog() {
        pendingTimeoutTask?.cancel()
        let scheduler = self
        pendingTimeoutTask = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                await scheduler.expirePlannerTimeouts()
            }
        }
    }

    // MARK: - Prefix-cache stats logger

    /// Spawn the periodic checkpoint-tier hit/miss logger. Called from
    /// `loadModel` after the checkpoint manager is installed; cancelled (and
    /// re-spawned) on every `stopCurrentEngine` / `loadModel` cycle. No-op when
    /// the interval is 0 (disabled) or there is no checkpoint manager (engine
    /// tier / cache off). Snapshots are cheap (a struct copy across the manager
    /// actor), so a 2-minute cadence is free.
    /// Periodic steady-state TTL sweep (PR #290 review). Cadence: half the
    /// TTL, clamped to [60, 300]s — frequent enough that an expired entry
    /// outlives its TTL by at most ~cadence, rare enough to be free (the sweep
    /// is an in-memory index scan; file deletes only when something expired).
    /// Independent of the stats logger so disabling observability never
    /// disables the privacy reaper.
    func startTTLReaper() {
        ttlReapTask?.cancel()
        ttlReapTask = nil
        let ttl = Self.prefixCacheTTLSeconds()
        guard ttl > 0, let mgr = checkpointManager else { return }
        let cadence = Swift.max(60, Swift.min(ttl / 2, 300))
        ttlReapTask = Task.detached { [weak mgr] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double(cadence)))
                if Task.isCancelled { return }
                await mgr?.reapExpiredTick()
            }
        }
    }

    func startPrefixCacheStatsLogger() {
        prefixCacheStatsTask?.cancel()
        prefixCacheStatsTask = nil
        let interval = Self.prefixCacheStatsIntervalSecs()
        guard interval > 0, checkpointManager != nil else { return }
        let scheduler = self
        prefixCacheStatsTask = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { return }
                await scheduler.logPrefixCacheStats()
            }
        }
    }

    /// Read the checkpoint manager's cumulative counters and emit one info
    /// line. Hit rate = (ramHits + ssdHits) / (ramHits + ssdHits + misses).
    /// `misses` here counts only lookups that found neither RAM nor SSD entry
    /// — i.e. genuine cold/unique prompts — so the rate reflects reuse of
    /// cacheable prefixes, not the unique-prompt floor the workload injects.
    func logPrefixCacheStats() async {
        guard let mgr = checkpointManager else { return }
        let s = await mgr.snapshotStats()
        let lookups = s.ramHits + s.ssdHits + s.misses
        let hits = s.ramHits + s.ssdHits
        let rate = lookups > 0 ? (Double(hits) * 100.0 / Double(lookups)) : 0.0
        // os.Logger redacts non-literal interpolations (String(format:)) as
        // <private> by default; mark the rate .public so the hit rate is
        // actually readable. Integer interpolations default to public already.
        let rateStr = String(format: "%.1f", rate)
        prefixCacheLogger.info(
            "prefix cache stats: lookups=\(lookups) hits=\(hits) (ram=\(s.ramHits) ssd=\(s.ssdHits)) misses=\(s.misses) hitRate=\(rateStr, privacy: .public)% stores=\(s.stores) ssdFlushes=\(s.ssdFlushes) diskEvictions=\(s.diskEvictions) ssdReadErrors=\(s.ssdReadErrors) modelMismatch=\(s.modelMismatches) shapeMismatch=\(s.shapeMismatches) prefixHashMismatch=\(s.prefixHashMismatches)")
    }

    /// Watchdog body: abort bridges still waiting for engine admission
    /// past `pendingTimeout`. A long prefill is admitted but emits no
    /// decoded token yet; admittedAt != nil filters those out so they
    /// are not mistakenly treated as "stuck in queue".
    func expirePlannerTimeouts() async {
        guard let engine = self.engine else { return }
        let now = ContinuousClock.now
        let timedOut = activeBridges.filter { _, bridge in
            bridge.admittedAt == nil
                && now - bridge.submittedAt >= pendingTimeout
        }
        var abortedLocally: [String] = []
        for (id, _) in timedOut {
            // Insert BEFORE abort so the streaming Task sees the flag
            // when it consumes the resulting terminal RequestOutput.
            timedOutBridges.insert(id)
            // AbortRequest returns false when the engine has no
            // collector for this id yet — the request is still mid-submit (its
            // `addRequest` engineQueue block hasn't run, so `runBridge`/the
            // output stream don't exist yet either). The engine abort is then a
            // no-op AND no terminal output will ever arrive, so the bridge would
            // sit in `activeBridges` past its timeout leaking KV/planner budget.
            // Drop it locally. Safe: a false return guarantees no engine
            // collector, hence no streaming Task consuming for this id; if its
            // add later lands, the bridge is gone and its outputs are no-ops.
            if !engine.core.abortRequest(id) {
                abortedLocally.append(id)
            }
        }
        for id in abortedLocally {
            await dropBridge(requestId: id)  // also clears the timedOutBridges flag
        }
        await refreshPendingSummaryCache()
    }
}

// MARK: - Test support
//
// `_testSeedBridge` injects a `BridgeState` without going through
// `submit()` (which requires a loaded model + non-nil engine). Used by
// non-live unit tests for the cumulative-budget gate and in-flight
// progress reporting. Internal access ensures it is only reachable via
// @testable import and is dead-code-stripped from production binaries.

extension BatchScheduler {
    func _testSeedBridge(
        id: String,
        promptTokens: Int,
        maxTokens: Int,
        admitted: Bool = false,
        reservedTokens: Int? = nil
    ) {
        var bridge = BridgeState(
            requestId: id,
            promptTokens: promptTokens,
            maxTokens: maxTokens,
            submittedAt: .now
        )
        bridge.reservedTokens = reservedTokens
        if admitted { bridge.admittedAt = .now }
        activeBridges[id] = bridge
    }

    /// Test accessor: is a bridge still tracked for `id`? This is the exact
    /// signal `confirmEnqueuedOrAbort` checks after `addRequest` to detect a
    /// request that was cancelled / timed-out while the submit task was
    /// suspended (the cancel/timeout path `dropBridge`'d it) and must therefore
    /// be aborted rather than handed to `runBridge`.
    func _bridgeIsActiveForTest(_ id: String) -> Bool {
        activeBridges[id] != nil
    }
}
