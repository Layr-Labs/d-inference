import Foundation
import MLXLMCommon

extension EngineV2Bridge {
    func setMeasurementActivity(_ activity: EngineMeasurementActivity) {
        measurementActivity = activity
    }

    /// Engine callback receipts are authoritative even if the actor has not yet
    /// installed active state or the answer later cancels. The receipt owns the
    /// once-only transition, so neither terminal delivery nor a reused ID can
    /// publish a second observation.
    func consumePrefillReceipt(id: String, receipt: EnginePrefillReceipt) {
        guard let sample = receipt.take() else { return }
        let usage = sample.usage
        let saved = max(usage.prefixCachePrefillTokensSaved, usage.prefixCacheHitTokens)
        guard usage.promptTokens > 0, saved >= 0, saved <= usage.promptTokens,
            usage.prefixCacheOutcome != .hit || saved > 0,
            usage.timing.promptComputedNanos > 0 else { return }
        let work = usage.promptTokens - saved
        prefillTokensTotal = Self.saturatingCounter(prefillTokensTotal, adding: work)
        prefillRequestsTotal = Self.saturatingCounter(prefillRequestsTotal, adding: 1)
        guard usage.timing.visionChunks == 0,
            saved > 0 ? usage.prefixCacheOutcome == .hit : Self.isColdPrefillSample(usage: usage),
            let seconds = EngineV2NativeBlockTiming.prefillSeconds(usage.timing),
            let tps = Self.classifyPrefillSample(prefilledTokens: work, prefillSeconds: seconds)
        else { return }
        let name = saved > 0 ? "reuse_prefill"
            : sample.overlap.contended ? "contended_prefill" : "isolated_prefill"
        performanceMeasurements.observe(name, tps: tps, prompt: work,
            context: usage.promptTokens, cache: saved > 0 ? "reused" : "cold",
            overlap: sample.overlap, at: sample.at)
        guard saved == 0 else { return }
        updatePrefillTpsEwma(tps, isolated: !sample.overlap.contended)
    }

    func updatePrefillTpsEwma(_ tps: Double, isolated: Bool) {
        observedPrefillTpsEwma = prefillEwmaInitialized
            ? 0.3 * tps + 0.7 * observedPrefillTpsEwma : tps
        prefillEwmaInitialized = true
        guard isolated else { return }
        isolatedPrefillTpsEwma = isolatedPrefillEwmaInitialized
            ? 0.3 * tps + 0.7 * isolatedPrefillTpsEwma : tps
        isolatedPrefillEwmaInitialized = true
    }

    static func saturatingCounter(_ counter: Int64, adding increment: Int) -> Int64 {
        let (sum, overflow) = counter.addingReportingOverflow(Int64(clamping: max(0, increment)))
        return overflow ? .max : sum
    }

    /// The engine interval ends at the last confirmed token, before terminal
    /// checkpointing, retirement, detokenization and bridge scheduling. Keep
    /// pauses inside that interval: lifetime pause totals cannot safely be
    /// subtracted from a narrower interval.
    static func engineDecodeRate(usage: CBv2Usage, nativeBlock: Bool) -> Double? {
        let timing = usage.timing
        let start = nativeBlock ? timing.promptComputedNanos : timing.firstTokenNanos
        let tokens = nativeBlock ? usage.completionTokens : usage.completionTokens - 1
        guard tokens > 0, start > 0, timing.lastTokenNanos > start,
            nativeBlock || timing.decodeSteps > 0 else { return nil }
        let seconds = Double(timing.lastTokenNanos - start) / 1_000_000_000
        let tps = Double(tokens) / seconds
        return tps.isFinite && tps > 0 && tps <= 20_000 ? tps : nil
    }

    static func engineObservationInstant(
        timing: CBv2RequestTiming, now: ContinuousClock.Instant,
        uptimeNanos: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> ContinuousClock.Instant? {
        let observed = timing.lastTokenUptimeNanos
        guard observed > 0, observed <= uptimeNanos else { return nil }
        let age = uptimeNanos - observed
        guard age <= UInt64(Int64.max) else { return nil }
        return now - .nanoseconds(Int64(age))
    }

    func recordPerformanceFinish(
        state: ActiveRequestState, usage: CBv2Usage, completion: Int,
        deliveredTps: Double, now: ContinuousClock.Instant
    ) {
        let overlap = state.prefillReceipt?.overlap
            ?? EngineMeasurementActivity.Overlap(contended: true, otherModel: true)
        let cached = max(usage.prefixCachePrefillTokensSaved, usage.prefixCacheHitTokens) > 0
        if let tps = Self.engineDecodeRate(usage: usage, nativeBlock: usesNativeBlockTiming),
            let observedAt = Self.engineObservationInstant(timing: usage.timing, now: now) {
            updateDecodeTpsEwma(tps)
            performanceMeasurements.observe("decode", tps: tps, prompt: state.promptTokens,
                context: state.promptTokens + completion, cache: cached ? "reused" : "cold",
                overlap: overlap, at: observedAt)
        }
        performanceMeasurements.observe("delivered_decode", tps: deliveredTps,
            prompt: state.promptTokens, context: state.promptTokens + completion,
            cache: cached ? "reused" : "cold", overlap: overlap, at: now)
        let seconds = WedgeMonitor.seconds(now - state.submittedAt)
        if seconds > 0 {
            performanceMeasurements.observe("end_to_end", tps: Double(completion) / seconds,
                prompt: state.promptTokens, context: state.promptTokens + completion,
                cache: cached ? "reused" : "cold", overlap: overlap, at: now)
        }
        recordGenerationWork(completion: completion)
    }

    func recordGenerationWork(completion: Int) {
        generatedTokensTotal = Self.saturatingCounter(generatedTokensTotal, adding: completion)
        generationRequestsTotal = Self.saturatingCounter(generationRequestsTotal, adding: 1)
    }

    /// A committed admission torn down before active state has no event pump.
    /// Reconcile numeric output exactly like normal accounting: terminal usage
    /// may raise the observed token count; a closed stream keeps confirmed
    /// deltas. Never expose text, update the caller's usage signal, or train a
    /// rate from this unobserved delivery interval.
    nonisolated static func transferredGenerationWork(
        in events: AsyncStream<CBv2Event>
    ) async -> Int {
        var completion = 0
        for await event in events {
            switch event {
            case .delta(_, let tokens, _):
                let (sum, overflow) = completion.addingReportingOverflow(tokens.count)
                completion = overflow ? .max : sum
            case .finished(_, let usage):
                return max(completion, usage.completionTokens)
            }
        }
        return completion
    }
}
