import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

extension EngineV2Bridge {
    func currentNativeMediaDeadlinePolicyForTest(requestID: String, promptTokens: Int)
        -> CBv2NativeTargetPrefillPolicy {
        nativeMediaDeadlinePolicy(requestID: requestID, promptTokens: promptTokens,
            evidence: captureNativeMediaRateEvidence(requestID: requestID))
    }
}

private func nativeRatePosture(at now: ContinuousClock.Instant) -> DeadlinePostureState {
    let posture = DeadlinePostureState()
    for tick in 0...12 {
        let at = now - .milliseconds((12 - tick) * 500)
        posture.observe(nominal: true, lowPower: false, automatic: true,
            source: "ac", powerReadAt: at, at: at)
    }
    return posture
}

private func nativeRateEvidence(at now: ContinuousClock.Instant) throws -> NativeMediaRateEvidence {
    let posture = nativeRatePosture(at: now)
    return .init(rate: try #require(posture.captureRateEvidence(at: now)),
        guardToken: .init(), validUntil: now + .seconds(1_000))
}

@Test func nativeMediaRatesKeepObservedDomainAndExpireEachSampleIndependently() throws {
    let now = ContinuousClock.now, evidence = try nativeRateEvidence(at: .now)
    var rates = NativeMediaPrefillRates()
    rates.observe(tokens: 1_100, rate: 100, epoch: evidence.rate.epoch,
        at: now - .seconds(119), now: now)
    rates.observe(tokens: 1_200, rate: 800, epoch: evidence.rate.epoch,
        at: now - .seconds(1), now: now)
    #expect(rates.observation(tokens: 1_150, evidence: evidence, now: now)?.tokensPerSecond == 100)
    #expect(rates.observation(tokens: 1_099, evidence: evidence, now: now) == nil)
    #expect(rates.observation(tokens: 1_201, evidence: evidence, now: now) == nil)
    // The newer fast sample cannot rejuvenate the old slow/setup sample.
    #expect(rates.observation(tokens: 1_150, evidence: evidence, now: now + .seconds(2)) == nil)
    #expect(rates.observation(tokens: 1_200, evidence: evidence, now: now + .seconds(2))?.tokensPerSecond == 800)
    #expect(rates.observation(tokens: 1_200, evidence: evidence, now: now + .seconds(121)) == nil)
}

@Test func nativeMediaRatesRejectForeignEpochInvalidRatesAndOutOfOrderRevival() throws {
    let now = ContinuousClock.now, evidence = try nativeRateEvidence(at: .now)
    var rates = NativeMediaPrefillRates()
    rates.observe(tokens: 1_200, rate: 800, epoch: evidence.rate.epoch, at: now, now: now)
    rates.observe(tokens: 1_100, rate: 100, epoch: evidence.rate.epoch,
        at: now - .seconds(121), now: now)
    for rate in [Double.nan, .infinity, -1, 0, 20_001] {
        rates.observe(tokens: 1_000, rate: rate, epoch: evidence.rate.epoch, at: now, now: now)
    }
    #expect(rates.observation(tokens: 1_100, evidence: evidence, now: now) == nil)
    #expect(rates.observation(tokens: 1_200, evidence: evidence, now: now)?.tokensPerSecond == 800)
    let foreign = try nativeRateEvidence(at: .now)
    #expect(rates.observation(tokens: 1_200, evidence: foreign, now: now) == nil)
    evidence.guardToken.invalidate()
    #expect(rates.observation(tokens: 1_200, evidence: evidence, now: now) == nil)
}

@Test func nativeMediaRateWindowIsBoundedAndDoesNotDropNewerDelayedReceipts() throws {
    let now = ContinuousClock.now, evidence = try nativeRateEvidence(at: .now)
    var rates = NativeMediaPrefillRates()
    for index in 0..<33 {
        rates.observe(tokens: 1_100 + index, rate: 500 + Double(index),
            epoch: evidence.rate.epoch, at: now - .milliseconds(100 - index), now: now)
    }
    #expect(rates.observation(tokens: 1_100, evidence: evidence, now: now) == nil)
    rates.observe(tokens: 1_200, rate: 700, epoch: evidence.rate.epoch,
        at: now - .milliseconds(80), now: now)
    #expect(rates.observation(tokens: 1_132, evidence: evidence, now: now) != nil)
}

@Test func nativeMediaWholeMacGuardRejectsConcurrentAndEncoderWorkAndPowerTransitions() throws {
    let now = ContinuousClock.now
    let posture = nativeRatePosture(at: now)
    let service = WholeMacServiceBudget(clockNow: { now }, posture: posture)
    #expect(service.acquire(ownerID: "target", concurrency: 4,
        work: .init(modelID: "native", profileID: nil, promptTokens: 1_100, maxOutputTokens: 1)))
    let first = try #require(service.captureNativeMediaRateEvidence(ownerID: "target", modelID: "native"))
    #expect(first.completedEpoch() != nil)
    let encoder = service.beginUnboundedActivity()
    #expect(first.completedEpoch() == nil)
    #expect(service.captureNativeMediaRateEvidence(ownerID: "target", modelID: "native") == nil)
    encoder.finish()
    let next = try #require(service.captureNativeMediaRateEvidence(ownerID: "target", modelID: "native"))
    #expect(service.acquire(ownerID: "other", concurrency: 4,
        work: .init(modelID: "text", profileID: nil, promptTokens: 1, maxOutputTokens: 1)))
    #expect(next.completedEpoch() == nil)
    #expect(service.captureNativeMediaRateEvidence(ownerID: "target", modelID: "native") == nil)
    service.release(ownerID: "other")
    let recovered = try #require(service.captureNativeMediaRateEvidence(ownerID: "target", modelID: "native"))
    posture.observe(nominal: true, lowPower: false, automatic: true, source: "battery",
        powerReadAt: now, at: now)
    #expect(recovered.completedEpoch() == nil)
    #expect(service.captureNativeMediaRateEvidence(ownerID: "target", modelID: "native") == nil)
    service.release(ownerID: "target")
}

@Test func nativeMediaRetiredWorkDoesNotBorrowReviewedTextQuiescence() throws {
    let now = ContinuousClock.now
    let posture = nativeRatePosture(at: now)
    let service = WholeMacServiceBudget(clockNow: { now }, posture: posture)
    let textRequirement = DeadlineApplicability(minimumWholeMacQuiescenceMs: 20_000,
        minimumNominalStabilityMs: 5_000, powerMode: "automatic")
    let preparation = service.beginUnboundedActivity()
    #expect(service.acquire(ownerID: "target", concurrency: 1,
        work: .init(modelID: "native", profileID: "reviewed", promptTokens: 1_100, maxOutputTokens: 1),
        deadlineApplicability: textRequirement))
    #expect(service.captureNativeMediaRateEvidence(ownerID: "target", modelID: "native") == nil)
    preparation.finish() // actual completion, not a timer or request terminal
    #expect(service.captureNativeMediaRateEvidence(ownerID: "target", modelID: "native") != nil)
    #expect(service.calibrationSnapshot(ownerID: "target", modelID: "native", profileID: "reviewed",
        applicability: textRequirement) == nil)
    service.release(ownerID: "target")
    #expect(!service.deadlineEligibleForAdvertisement(textRequirement))
}

@Test func nativeMediaBootstrapIsOneAtATimeAndRetainsCooldownAfterRelease() async throws {
    let posture = nativeRatePosture(at: .now)
    let service = WholeMacServiceBudget(posture: posture)
    let budget = GlobalKVCacheBudget(memorySnapshot: {
        .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: 64 << 30)
    }, serviceBudget: service)
    let bridge = EngineV2Bridge(engine: PrefillScriptEngine(), modelId: "native",
        tokenizer: TokenizerHandle(PrefillStubTokenizer()), eosTokenIds: [], kvBudget: budget)
    #expect(await bridge.acquireServiceAllowance(requestID: "first", promptTokens: 1_100, maxOutputTokens: 1))
    #expect(await bridge.currentNativeMediaDeadlinePolicyForTest(requestID: "first", promptTokens: 1_100).bootstrap != nil)
    #expect(await bridge.currentNativeMediaDeadlinePolicyForTest(requestID: "first", promptTokens: 1_200).bootstrap == nil)
    await bridge.releaseServiceAllowance(requestID: "first")
    #expect(await bridge.nativeMediaBootstrapRequestID == nil)
    #expect(await bridge.acquireServiceAllowance(requestID: "second", promptTokens: 1_200, maxOutputTokens: 1))
    #expect(await bridge.currentNativeMediaDeadlinePolicyForTest(requestID: "second", promptTokens: 1_200).bootstrap == nil)
    await bridge.releaseServiceAllowance(requestID: "second")
    await bridge.shutdown()
}

@Test(arguments: ["cold", "contended", "reused", "readmitted", "packed", "missing_epoch"])
func nativeMediaReceiptLearnsOnlyIsolatedColdTargetWorkAndNeverTrainsText(kind: String) async throws {
    let posture = nativeRatePosture(at: .now)
    let service = WholeMacServiceBudget(posture: posture)
    let budget = GlobalKVCacheBudget(memorySnapshot: {
        .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: 64 << 30)
    }, serviceBudget: service)
    let bridge = EngineV2Bridge(engine: PrefillScriptEngine(), modelId: "native",
        tokenizer: TokenizerHandle(PrefillStubTokenizer()), eosTokenIds: [], kvBudget: budget)
    #expect(await bridge.acquireServiceAllowance(requestID: "target", promptTokens: 1_000, maxOutputTokens: 1))
    let evidence = try #require(await bridge.captureNativeMediaRateEvidence(requestID: "target"))
    let activity = EngineMeasurementActivity()
    let competing = kind == "contended" ? EnginePrefillReceipt(activity: activity, model: "other") : nil
    let receipt = EnginePrefillReceipt(activity: activity, model: "native", nativeCausalMedia: true,
        nativeRateEvidence: kind == "missing_epoch" ? nil : evidence)
    var usage = CBv2Usage(promptTokens: 1_000, completionTokens: 0,
        prefixCacheOutcome: kind == "reused" ? .hit : .miss,
        prefixCachePrefillTokensSaved: kind == "reused" ? 100 : 0)
    usage.timing.prefillFirstLaunchNanos = 1_000_000
    usage.timing.promptComputedNanos = 101_000_000
    usage.timing.visionChunks = 1
    usage.timing.readmissions = kind == "readmitted" ? 1 : 0
    usage.timing.packedPrefillChunks = kind == "packed" ? 1 : 0
    receipt.complete(usage)
    await bridge.consumePrefillReceipt(id: "target", receipt: receipt)
    await bridge.consumePrefillReceipt(id: "target", receipt: receipt)
    let measurements = await bridge.performanceMeasurementSnapshot(now: .now)
    #expect(measurements.isolatedPrefill == nil && measurements.contendedPrefill == nil)
    #expect(measurements.workloadBuckets.count == 1)
    #expect(measurements.workloadBuckets.first?.phase == "native_media_prefill")
    #expect(measurements.workloadBuckets.first?.observation.sampleCount == 1)
    let policy = await bridge.currentNativeMediaDeadlinePolicyForTest(requestID: "target", promptTokens: 1_000)
    #expect((policy.observation != nil) == (kind == "cold"))
    receipt.end(); competing?.end()
    await bridge.releaseServiceAllowance(requestID: "target")
    await bridge.shutdown()
}

@Test func nativeMediaOrdinarySampleReleasesFailedBootstrapCooldownOnlyAtItsRetirement() async throws {
    let posture = nativeRatePosture(at: .now)
    let service = WholeMacServiceBudget(posture: posture)
    let budget = GlobalKVCacheBudget(memorySnapshot: {
        .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: 64 << 30)
    }, serviceBudget: service)
    let bridge = EngineV2Bridge(engine: PrefillScriptEngine(), modelId: "native",
        tokenizer: TokenizerHandle(PrefillStubTokenizer()), eosTokenIds: [], kvBudget: budget)
    #expect(await bridge.acquireServiceAllowance(requestID: "failed", promptTokens: 1_100, maxOutputTokens: 1))
    #expect(await bridge.currentNativeMediaDeadlinePolicyForTest(requestID: "failed", promptTokens: 1_100).bootstrap != nil)
    await bridge.releaseServiceAllowance(requestID: "failed")
    #expect(await bridge.nextNativeMediaBootstrapAt != nil)

    // An ordinary/exempt native request has no bootstrap ID, but can still
    // supply real, eligible target-prefill evidence during the backoff.
    #expect(await bridge.acquireServiceAllowance(requestID: "ordinary", promptTokens: 1_000, maxOutputTokens: 1))
    let evidence = try #require(await bridge.captureNativeMediaRateEvidence(requestID: "ordinary"))
    let receipt = EnginePrefillReceipt(activity: .init(), model: "native", nativeCausalMedia: true,
        nativeRateEvidence: evidence)
    var usage = CBv2Usage(promptTokens: 1_000, completionTokens: 0, prefixCacheOutcome: .miss)
    usage.timing.prefillFirstLaunchNanos = 1_000_000
    usage.timing.promptComputedNanos = 101_000_000
    usage.timing.visionChunks = 1
    receipt.complete(usage)
    await bridge.consumePrefillReceipt(id: "ordinary", receipt: receipt)
    #expect(await bridge.nativeMediaLearnedRequestIDs == ["ordinary"])
    #expect(await bridge.nextNativeMediaBootstrapAt != nil)
    await bridge.releaseServiceAllowance(requestID: "unrelated")
    #expect(await bridge.nextNativeMediaBootstrapAt != nil)
    receipt.end()
    await bridge.releaseServiceAllowance(requestID: "ordinary")
    #expect(await bridge.nativeMediaLearnedRequestIDs.isEmpty)
    #expect(await bridge.nextNativeMediaBootstrapAt == nil)
    #expect(await bridge.acquireServiceAllowance(requestID: "new-shape", promptTokens: 1_200, maxOutputTokens: 1))
    #expect(await bridge.currentNativeMediaDeadlinePolicyForTest(requestID: "new-shape", promptTokens: 1_200).bootstrap != nil)
    await bridge.releaseServiceAllowance(requestID: "new-shape")
    await bridge.shutdown()
}

@Test func nativeMediaAdmissionUsesTheReceiptSnapshotWithoutRecapturingFreshPosture() async throws {
    let posture = DeadlinePostureState()
    let service = WholeMacServiceBudget(posture: posture)
    let budget = GlobalKVCacheBudget(memorySnapshot: {
        .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: 64 << 30)
    }, serviceBudget: service)
    let bridge = EngineV2Bridge(engine: PrefillScriptEngine(), modelId: "native",
        tokenizer: TokenizerHandle(PrefillStubTokenizer()), eosTokenIds: [], kvBudget: budget)
    #expect(await bridge.acquireServiceAllowance(requestID: "target", promptTokens: 1_000, maxOutputTokens: 1))
    let unavailable = await bridge.captureNativeMediaRateEvidence(requestID: "target")
    #expect(unavailable == nil)
    let now = ContinuousClock.now
    for tick in 0...12 {
        let at = now - .milliseconds((12 - tick) * 500)
        posture.observe(nominal: true, lowPower: false, automatic: true,
            source: "ac", powerReadAt: at, at: at)
    }
    // Posture is now eligible. The old nil receipt must not silently gain a
    // bootstrap permit that could never authorize its completion measurement.
    let missing = await bridge.nativeMediaDeadlinePolicy(requestID: "target", promptTokens: 1_000,
        evidence: unavailable)
    #expect(missing.bootstrap == nil && missing.observation == nil)
    #expect(await bridge.nativeMediaBootstrapRequestID == nil)

    let evidence = try #require(await bridge.captureNativeMediaRateEvidence(requestID: "target"))
    let receipt = EnginePrefillReceipt(activity: .init(), model: "native", nativeCausalMedia: true,
        nativeRateEvidence: evidence)
    let policy = await bridge.nativeMediaDeadlinePolicy(requestID: "target", promptTokens: 1_000,
        evidence: evidence)
    let bootstrap = try #require(policy.bootstrap)
    #expect(bootstrap.evidenceGuard === receipt.nativeRateEvidence?.guardToken)
    #expect(bootstrap.validUntil == receipt.nativeRateEvidence?.validUntil)
    let encoder = service.beginUnboundedActivity()
    #expect(!bootstrap.evidenceGuard.isValid)
    #expect(receipt.nativeRateEvidence?.completedEpoch() == nil)
    encoder.finish(); receipt.end()
    await bridge.releaseServiceAllowance(requestID: "target")
    await bridge.shutdown()
}
