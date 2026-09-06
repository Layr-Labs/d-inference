// Request token accounting and measured prefill/decode rates for admission and routing.

import Foundation
import MLXLMCommon

extension EngineV2Bridge {
    // MARK: - Bookkeeping

    func recordFirstToken(
        id: String, emissionTokens: Int, profileNow: SuspendingClock.Instant? = nil
    ) {
        let now = ContinuousClock.Instant.now
        wedgeMonitor.recordFirstToken(now: now)
        guard var state = active[id] else { return }
        if state.firstTokenAt == nil {
            state.firstTokenAt = now
            state.firstEmissionTokens = max(1, emissionTokens)
            active[id] = state
            // Profiler `first_delta_us`: the same instant the pump stored as
            // its last-delta, so a one-token response keeps first ≤ last.
            // Clamped to `terminal_built`: on the cancel path the handler
            // builds its terminal BEFORE the engine delivers `.finished`, so a
            // late delta must never land after it (wire order invariant).
            if let profileNow, let profile = state.profile {
                profile.mark(
                    .firstDelta, at: profileNow,
                    notBefore: .engineAdmitted, notAfter: .terminalBuilt)
            }
        }
    }

    func recordProgress(id: String, newTokens: Int) {
        guard newTokens > 0 else { return }
        active[id]?.completionTokens += newTokens
    }

    /// Terminal usage can raise observed token counts, never erase them.
    /// Report decode rate over first-token→finish using completion - 1 tokens.
    func recordFinish(
        id: String,
        usage: CBv2Usage,
        success: Bool,
        lastDeltaAt: SuspendingClock.Instant? = nil,
        finishReason: CBv2FinishReason? = nil
    ) -> (prompt: Int, completion: Int, tps: Double) {
        idMap.removeValue(forKey: id)
        let now = ContinuousClock.Instant.now
        guard var state = active.removeValue(forKey: id) else {
            return (max(0, usage.promptTokens), max(0, usage.completionTokens), 0)
        }
        state.completionTokens = max(state.completionTokens, usage.completionTokens)
        let prompt = max(state.promptTokens, usage.promptTokens)
        let completion = state.completionTokens

        // Profiler: cumulative cold-prefill tokens for the heartbeat (the
        // cached count is only known from terminal usage, so attribution
        // lands at finish, not first token) and the per-request finish
        // fields — ONE lock.
        let cachedTokens = max(
            0,
            usage.prefixCacheHitTokens,
            usage.prefixCacheMatchedTokens,
            usage.prefixCachePrefillTokensSaved)
        let (nextPrefillTotal, prefillOverflow) = prefillTokensTotal
            .addingReportingOverflow(Int64(max(0, prompt - cachedTokens)))
        prefillTokensTotal = prefillOverflow ? .max : nextPrefillTotal
        if let profile = state.profile {
            let stepsNow = Int64(capacitySnapshot().stepsExecuted)
            let lastDeltaOffset = lastDeltaAt.map { profile.offsetUs(of: $0) }
            let completionNow = Int64(completion)
            var tokensAfterCancel: Int64?
            var tokensAfterCancelHook: (@Sendable (Int64) -> Void)?
            profile.update { f, _ in
                if let lastDeltaOffset {
                    // Same ceiling as `first_delta`: never past the handler's
                    // (possibly already built) terminal.
                    f.mark(.lastDelta,
                           offsetUs: f.clamp(
                               lastDeltaOffset, notBefore: .firstDelta, notAfter: .terminalBuilt))
                }
                f.set(.stepsAtFinish, max(stepsNow, f.count(.stepsAtSubmit) ?? 0))
                if let atCancel = f.count(.tokensAtCancel) {
                    let after = max(0, completionNow - atCancel)
                    f.set(.tokensAfterCancel, after)
                    tokensAfterCancel = after
                    tokensAfterCancelHook = f.onTokensAfterCancel
                }
                f.engine = EngineProfile(timing: usage.timing, finishReason: finishReason)
            }
            // Cumulative heartbeat counter, bumped HERE (outside the lock):
            // the handler task's defer may already have run when a cancelled
            // request's engine terminal arrives, so it cannot own this add.
            if let tokensAfterCancel {
                tokensAfterCancelHook?(tokensAfterCancel)
            }
        }

        let tps: Double
        if let firstTokenAt = state.firstTokenAt, completion > 1 {
            let seconds = WedgeMonitor.seconds(now - firstTokenAt)
            tps = seconds > 0 ? Double(completion - 1) / seconds : 0
        } else {
            let seconds = WedgeMonitor.seconds(now - state.submittedAt)
            tps = seconds > 0 ? Double(completion) / seconds : 0
        }
        // Only tokens emitted strictly after the first engine emission are a
        // decode observation. MTP can deliver several accepted tokens in that
        // first burst; charging all but one over a near-zero interval would
        // catastrophically inflate the conservative decode rate.
        if success, let firstTokenAt = state.firstTokenAt,
            completion > state.firstEmissionTokens
        {
            let decodeSeconds = WedgeMonitor.seconds(now - firstTokenAt)
            let decodeTokens = completion - state.firstEmissionTokens
            let decodeTps =
                decodeSeconds > 0 ? Double(decodeTokens) / decodeSeconds : 0
            if decodeTps > 0 {
                updateDecodeTpsEwma(decodeTps)
            }
        }
        if success {
            recordPrefillSample(
                promptTokens: prompt,
                usage: usage,
                submittedAt: state.submittedAt,
                firstTokenAt: state.firstTokenAt,
                isolatedAtSubmit: state.isolatedPrefillSampleEligible)
        }
        return (prompt, completion, tps)
    }

    // MARK: - Prefill sampling (observed_prefill_tps)

    /// Minimum submit→first-token window (seconds) for a prefill sample to
    /// count. A near-zero window (scripted engines, degenerate prompts)
    /// divides into an absurd rate; 1 ms is far below any real cold
    /// prefill.
    static let minPrefillWindowSeconds = 0.001

    /// Upper plausibility bound (tok/s) for a prefill sample — PR #454's
    /// raised ceiling: above the MEASURED real-prefill p90 (~17,707 tok/s,
    /// docs/reports/2026-06-22-live-prefill-tps-check.md) so a legitimately
    /// fast cold prefill registers, finite so a window-collapse artifact is
    /// still rejected.
    static let maxPlausiblePrefillTps = 20_000.0

    /// Classify one prefill sample against the plausibility bounds.
    /// The window starts at the atomic engine-queue
    /// admission instant, not before that queue await; admission delay is
    /// therefore never smuggled into isolated prefill throughput. Isolation
    /// is revoked if another row arrives before this row's first token.
    static func classifyPrefillSample(
        prefilledTokens: Int, prefillSeconds: Double
    ) -> Double? {
        guard prefilledTokens > 0 else { return nil }
        guard prefillSeconds >= minPrefillWindowSeconds else { return nil }
        let tps = Double(prefilledTokens) / prefillSeconds
        guard tps.isFinite, tps <= maxPlausiblePrefillTps else { return nil }
        return tps
    }

    /// Feed the prefill EWMA (α = 0.3, mirroring the decode EWMA) from a
    /// successful request's timing only when terminal engine usage proves the
    /// request performed a cold prefill. Cache hits have a different latency
    /// distribution and must never calibrate the coordinator's cold TTFT model.
    private func recordPrefillSample(
        promptTokens: Int,
        usage: CBv2Usage,
        submittedAt: ContinuousClock.Instant,
        firstTokenAt: ContinuousClock.Instant?,
        isolatedAtSubmit: Bool
    ) {
        guard Self.isColdPrefillSample(usage: usage) else { return }
        guard let firstTokenAt else { return }
        let prefillSeconds = WedgeMonitor.seconds(firstTokenAt - submittedAt)
        guard
            let tps = Self.classifyPrefillSample(
                prefilledTokens: promptTokens, prefillSeconds: prefillSeconds)
        else { return }
        let alpha = 0.3
        if prefillEwmaInitialized {
            observedPrefillTpsEwma = alpha * tps + (1 - alpha) * observedPrefillTpsEwma
        } else {
            observedPrefillTpsEwma = tps
            prefillEwmaInitialized = true
        }
        guard isolatedAtSubmit else { return }
        if isolatedPrefillEwmaInitialized {
            isolatedPrefillTpsEwma =
                alpha * tps + (1 - alpha) * isolatedPrefillTpsEwma
        } else {
            isolatedPrefillTpsEwma = tps
            isolatedPrefillEwmaInitialized = true
        }
    }

    static func isColdPrefillSample(usage: CBv2Usage) -> Bool {
        guard usage.prefixCacheOutcome != .hit else { return false }
        return max(
            usage.prefixCacheHitTokens,
            usage.prefixCacheMatchedTokens,
            usage.prefixCachePrefillTokensSaved
        ) <= 0
    }

    /// Stream torn down without a terminal event — drop local state.
    func dropRequest(id: String) {
        active.removeValue(forKey: id)
        idMap.removeValue(forKey: id)
    }

    /// Smooth successful decode observations for the routing heartbeat.
    private func updateDecodeTpsEwma(_ tps: Double) {
        guard tps.isFinite, tps > 0 else { return }
        let alpha = 0.3
        if ewmaInitialized {
            observedDecodeTpsEwma = alpha * tps + (1 - alpha) * observedDecodeTpsEwma
        } else {
            observedDecodeTpsEwma = tps
            ewmaInitialized = true
        }
    }
}
