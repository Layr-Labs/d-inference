import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

private final class RateEpochClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    var now: ContinuousClock.Instant { lock.withLock { instant } }
    func advance() { lock.withLock { instant = instant.advanced(by: .milliseconds(500)) } }
}

@Test func deadlineRatesRequireNewMeasurementsAfterPowerRecoveryWithoutReusingOldEWMA() async throws {
    let clock = RateEpochClock(), posture = DeadlinePostureState()
    func observe(_ source: String = "ac") {
        posture.observe(nominal: true, lowPower: false, automatic: true, source: source,
            powerReadAt: clock.now, at: clock.now)
    }
    func stable() { for _ in 0..<40 { clock.advance(); observe() } }
    observe(); stable()
    let service = WholeMacServiceBudget(clockNow: { clock.now }, posture: posture)
    let budget = GlobalKVCacheBudget(memorySnapshot: {
        .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: 64 << 30)
    }, serviceBudget: service)
    let profile = deadlineCalibrationProfileFixture()
    let bridge = EngineV2Bridge(engine: PrefillScriptEngine(), modelId: profile.modelId,
        tokenizer: TokenizerHandle(RateEpochTokenizer()), eosTokenIds: [], deadlineProfile: profile,
        promptWorkIdentity: .init(modelArtifactHash: profile.artifactSha256,
            promptContractID: profile.deadlineCalibration.promptContractId), kvBudget: budget)
    let prompt = PromptWork(source: "exact_contract", promptTokens: 8_828, upperBoundTokens: 8_828,
        promptContractID: profile.deadlineCalibration.promptContractId, modelArtifactHash: profile.artifactSha256)
    let oldEpoch = try #require(service.currentDeadlineRateEpoch(at: clock.now))
    await bridge.seedRateEpochTest(now: clock.now, postureEpoch: oldEpoch, rate: 1_000)
    let before = await bridge.performanceMeasurementSnapshot(now: clock.now)
    #expect(before.isolatedPrefill?.sampleCount == 1 && before.decode?.sampleCount == 1)

    observe("battery")
    let invalid = await bridge.performanceMeasurementSnapshot(now: clock.now)
    #expect(invalid.epoch == before.epoch && invalid.isolatedPrefill == nil && invalid.decode == nil)
    observe(); stable()
    let recoveredEpoch = try #require(service.currentDeadlineRateEpoch(at: clock.now))
    #expect(recoveredEpoch != oldEpoch)
    let recovered = await bridge.performanceMeasurementSnapshot(now: clock.now)
    #expect(recovered.epoch == before.epoch && recovered.isolatedPrefill == nil && recovered.decode == nil)
    #expect(await bridge.genericRateEpochTest(now: clock.now) == 1_000)
    #expect(await bridge.acquireServiceAllowance(requestID: "target", promptTokens: 8_828,
        maxOutputTokens: 128, allowExpansion: true))
    #expect(await bridge.calibratedDeadlinePolicy(requestID: "target", promptTokens: 8_828,
        promptWork: prompt, now: clock.now, allowQualifiedPosture: true) == nil)

    await bridge.seedRateEpochTest(now: clock.now, postureEpoch: recoveredEpoch, rate: 400)
    let refreshed = await bridge.performanceMeasurementSnapshot(now: clock.now)
    #expect(refreshed.epoch == before.epoch)
    #expect(refreshed.isolatedPrefill?.sampleCount == 2 && refreshed.decode?.sampleCount == 2)
    #expect(refreshed.isolatedPrefill?.tokensPerSecond == 400) // no old 1,000-TPS contribution
    #expect(refreshed.decode?.tokensPerSecond == 400)
    #expect(await bridge.calibratedDeadlinePolicy(requestID: "target", promptTokens: 8_828,
        promptWork: prompt, now: clock.now, allowQualifiedPosture: true) != nil)
    await bridge.releaseServiceAllowance(requestID: "target")
    await bridge.shutdown()
}

@Test func deadlineRateReceiptRejectsAnIntervalSpanningPostureInvalidation() throws {
    let posture = DeadlinePostureState()
    func observe(_ source: String) {
        posture.observe(nominal: true, lowPower: false, automatic: true, source: source,
            powerReadAt: .now, at: .now)
    }
    observe("ac")
    let evidence = try #require(posture.captureRateEvidence())
    let receipt = EnginePrefillReceipt(activity: EngineMeasurementActivity(), model: "model",
        deadlineRateEvidence: evidence)
    observe("battery"); observe("ac")
    receipt.complete(CBv2Usage(promptTokens: 4_096, completionTokens: 1))
    #expect(try #require(receipt.take()).deadlineRateEvidence == nil)
    #expect(evidence.currentEpoch() == nil)
    let fresh = try #require(posture.captureRateEvidence())
    #expect(fresh.epoch != evidence.epoch && fresh.currentEpoch() != nil)
    receipt.end()
}

@Test func deadlineRateFilteringDoesNotRemoveGenericMeasurementsFromUnqualifiedModels() async {
    let bridge = EngineV2Bridge(engine: PrefillScriptEngine(), modelId: "unqualified",
        tokenizer: TokenizerHandle(RateEpochTokenizer()), eosTokenIds: [])
    let now = ContinuousClock.now
    await bridge.seedRateEpochTest(now: now, postureEpoch: nil, rate: 700)
    let snapshot = await bridge.performanceMeasurementSnapshot(now: now)
    #expect(snapshot.isolatedPrefill?.tokensPerSecond == 700 && snapshot.decode?.tokensPerSecond == 700)
    await bridge.shutdown()
}

private extension EngineV2Bridge {
    func seedRateEpochTest(now: ContinuousClock.Instant, postureEpoch: UUID?, rate: Double) {
        for phase in ["isolated_prefill", "decode"] {
            performanceMeasurements.observe(phase, tps: rate, prompt: 8_828, context: 8_828,
                cache: "cold", overlap: .init(), at: now, deadlinePostureEpoch: postureEpoch)
        }
    }
    func genericRateEpochTest(now: ContinuousClock.Instant) -> Double? {
        performanceMeasurements.freshRate("isolated_prefill", now: now)
    }
}

private struct RateEpochTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [1] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "test" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?) throws -> [Int] { [1] }
}
