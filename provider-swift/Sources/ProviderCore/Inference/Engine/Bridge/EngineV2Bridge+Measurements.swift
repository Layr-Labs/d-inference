import Foundation
import MLXLMCommon

extension EngineV2Bridge {
    func setMeasurementActivity(_ activity: EngineMeasurementActivity, updates: EnginePerformanceUpdates? = nil) {
        measurementActivity = activity
        performanceUpdates = updates
    }

    /// Engine callback receipts are authoritative even if the actor has not yet
    /// installed active state or the answer later cancels. The receipt owns the
    /// once-only transition, so neither terminal delivery nor a reused ID can
    /// publish a second observation.
    func consumePrefillReceipt(id: String, receipt: EnginePrefillReceipt) {
        guard let sample = receipt.take() else { return }
        if prefillEvidenceRecovery.owner == id {
            // The SDK callback proves prompt completion even if cache reuse or
            // contention prevents a new cold rate. Keep the ordinary lease and
            // all KV/cache resources through generation-bound retirement.
            serviceBudget?.reduceExclusiveAllowance(ownerID: serviceOwnerPrefix + ":" + id,
                concurrency: prefillEvidenceRecovery.servingConcurrency)
        }
        let usage = sample.usage
        let saved = max(usage.prefixCachePrefillTokensSaved, usage.prefixCacheHitTokens)
        guard usage.promptTokens > 0, saved >= 0, saved <= usage.promptTokens,
            usage.prefixCacheOutcome != .hit || saved > 0,
            usage.timing.promptComputedNanos > 0 else { return }
        let work = usage.promptTokens - saved
        prefillTokensTotal = Self.saturatingCounter(prefillTokensTotal, adding: work)
        prefillRequestsTotal = Self.saturatingCounter(prefillRequestsTotal, adding: 1)
        // Valid computed work is useful even when vision/reuse or the timing
        // window excludes the rate. Publish after all counters and EWMAs agree.
        defer { performanceUpdates?.notify() }
        guard usage.timing.visionChunks == 0 || receipt.nativeCausalMedia,
            saved > 0 ? usage.prefixCacheOutcome == .hit : Self.isColdPrefillSample(usage: usage),
            let seconds = EngineV2NativeBlockTiming.prefillSeconds(usage.timing),
            let tps = Self.classifyPrefillSample(prefilledTokens: work, prefillSeconds: seconds)
        else { return }
        if receipt.nativeCausalMedia {
            // Native media features are fully prepared before submission.
            // This interval measures only the target decoder's computed
            // suffix. Keep the sample's size, reuse and overlap separate;
            // a text-only rate must not erase the evidence needed to calibrate
            // media. These diagnostic buckets do not change admission rates.
            performanceMeasurements.observe("native_media_prefill", tps: tps,
                prompt: work, context: usage.promptTokens,
                cache: saved > 0 ? "reused" : "cold",
                overlap: sample.overlap, at: sample.at)
            if saved == 0, !sample.overlap.contended,
                usage.timing.preemptions == 0, usage.timing.readmissions == 0,
                usage.timing.packedPrefillChunks == 0,
                let epoch = sample.nativeMediaRateEpoch,
                serviceBudget?.currentDeadlineRateEpoch() == epoch {
                if nativeMediaPrefillRates.observe(tokens: work, rate: tps, epoch: epoch, at: sample.at) {
                    // An ordinary/exempt request can supply eligible evidence
                    // after a failed bootstrap. Its own retirement owns the reset.
                    nativeMediaLearnedRequestIDs.insert(id)
                }
            }
            return
        }
        let name = saved > 0 ? "reuse_prefill"
            : sample.overlap.contended ? "contended_prefill" : "isolated_prefill"
        let resetIsolated = name == "isolated_prefill" && isolatedPrefillEvidenceExpired(at: sample.at)
        let resetPrefill = saved == 0
            && performanceMeasurements.freshRate("isolated_prefill", now: sample.at) == nil
            && performanceMeasurements.freshRate("contended_prefill", now: sample.at) == nil
        performanceMeasurements.observe(name, tps: tps, prompt: work,
            context: usage.promptTokens, cache: saved > 0 ? "reused" : "cold",
            overlap: sample.overlap, at: sample.at,
            deadlinePostureEpoch: sample.deadlineRateEvidence?.currentEpoch())
        guard saved == 0 else { return }
        if resetIsolated { isolatedPrefillEwmaInitialized = false }
        if resetPrefill { prefillEwmaInitialized = false }
        updatePrefillTpsEwma(tps, isolated: !sample.overlap.contended)
        if name == "isolated_prefill" { prefillEvidenceRecovery.observe(id) }
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
            if let expiration = performanceMeasurements.rateExpiration("decode"), observedAt > expiration {
                ewmaInitialized = false
            }
            updateDecodeTpsEwma(tps)
            performanceMeasurements.observe("decode", tps: tps, prompt: state.promptTokens,
                context: state.promptTokens + completion, cache: cached ? "reused" : "cold",
                overlap: overlap, at: observedAt,
                deadlinePostureEpoch: state.prefillReceipt?.deadlineRateEvidence?.currentEpoch())
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
        performanceUpdates?.notify()
    }

    func performanceMeasurementSnapshot(now: ContinuousClock.Instant) -> PerformanceMeasurements {
        guard deadlineProfile != nil else { return performanceMeasurements.snapshot(now: now) }
        return performanceMeasurements.deadlineSnapshot(now: now,
            postureEpoch: serviceBudget?.currentDeadlineRateEpoch(at: now))
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
