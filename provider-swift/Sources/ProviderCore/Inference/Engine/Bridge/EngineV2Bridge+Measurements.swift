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
        let calibration = receipt.calibrationCell
        // Engine retirement does not join the callback's actor Task. Discard a
        // late calibration receipt after cell validation/cleanup; never publish
        // it as independent serving evidence or count it as customer work.
        guard calibration == nil || modelCalibration.requests[id] != nil else { return }
        if prefillEvidenceRecovery.owner == id {
            // The SDK callback proves prompt completion even if cache reuse or
            // contention prevents a new cold rate. Keep the ordinary lease and
            // all KV/cache resources through generation-bound retirement.
            serviceBudget?.reduceExclusiveAllowance(ownerID: serviceOwnerPrefix + ":" + id,
                concurrency: prefillEvidenceRecovery.servingConcurrency)
        }
        guard calibration?.warmup != true else { return }
        let usage = sample.usage
        let saved = max(usage.prefixCachePrefillTokensSaved, usage.prefixCacheHitTokens)
        guard usage.promptTokens > 0, saved >= 0, saved <= usage.promptTokens,
            usage.prefixCacheOutcome != .hit || saved > 0,
            usage.timing.promptComputedNanos > 0 else { return }
        let work = usage.promptTokens - saved
        if calibration == nil {
            prefillTokensTotal = Self.saturatingCounter(prefillTokensTotal, adding: work)
            prefillRequestsTotal = Self.saturatingCounter(prefillRequestsTotal, adding: 1)
        }
        // Valid computed work is useful even when vision/reuse or the timing
        // window excludes the rate. Publish after all counters and EWMAs agree.
        defer { performanceUpdates?.notify() }
        guard receipt.measurementPurpose == .serving else { return }
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
        recordRateObservation(EngineRateObservation(
            phase: name, tps: tps, prompt: work, context: usage.promptTokens,
            cache: saved > 0 ? "reused" : "cold", overlap: sample.overlap, at: sample.at,
            postureEpoch: sample.deadlineRateEvidence?.currentEpoch(),
            aggregate: calibration == nil || (calibration?.width == 1 && !sample.overlap.contended)),
            requestID: id)
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

    /// The decode steps behind `engineDecodeRate`: mean token-producing rows
    /// over the steps that confirmed this request's tokens (its first-token
    /// step plus decode steps), and confirmed tokens and assigned width per
    /// decode step. Native block engines serve one plain row per step.
    static func engineDecodeShape(usage: CBv2Usage, nativeBlock: Bool) -> CBv2DecodeRateShape {
        let timing = usage.timing
        let decodeSteps = Double(timing.decodeSteps)
        guard !nativeBlock, decodeSteps > 0 else { return .init(batchRows: 1) }
        func clamped(_ value: Double) -> Double { value.isFinite ? min(64, max(1, value)) : 1 }
        let tokensPerStep = clamped(Double(max(0, usage.completionTokens - 1)) / decodeSteps)
        return .init(
            batchRows: clamped(Double(timing.batchRowsSum) / (decodeSteps + 1)),
            tokensPerStep: tokensPerStep,
            stepWidth: max(tokensPerStep, clamped(1 + Double(timing.mtpProposed) / decodeSteps)))
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
        id: String, state: ActiveRequestState, usage: CBv2Usage, completion: Int,
        deliveredTps: Double, now: ContinuousClock.Instant
    ) {
        let calibration = modelCalibration.requests[id]
        guard calibration?.warmup != true else { return }
        guard state.prefillReceipt?.measurementPurpose != .startupWarmup else {
            recordGenerationWork(completion: completion)
            return
        }
        let overlap = state.prefillReceipt?.overlap
            ?? EngineMeasurementActivity.Overlap(contended: true, otherModel: true)
        let cached = max(usage.prefixCachePrefillTokensSaved, usage.prefixCacheHitTokens) > 0
        if let tps = Self.engineDecodeRate(usage: usage, nativeBlock: usesNativeBlockTiming),
            let observedAt = Self.engineObservationInstant(timing: usage.timing, now: now) {
            recordRateObservation(EngineRateObservation(
                phase: "decode", tps: tps, prompt: state.promptTokens,
                context: state.promptTokens + completion, cache: cached ? "reused" : "cold",
                overlap: overlap, at: observedAt,
                postureEpoch: state.prefillReceipt?.deadlineRateEvidence?.currentEpoch(),
                aggregate: calibration == nil || (calibration?.width == 1 && !overlap.contended),
                decodeShape: Self.engineDecodeShape(usage: usage, nativeBlock: usesNativeBlockTiming)),
                requestID: id)
        }
        if calibration != nil { performanceUpdates?.notify(); return }
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

    func recordGenerationWork(completion: Int, requestID: String? = nil) {
        if let requestID, modelCalibration.requests[requestID] != nil { return }
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
