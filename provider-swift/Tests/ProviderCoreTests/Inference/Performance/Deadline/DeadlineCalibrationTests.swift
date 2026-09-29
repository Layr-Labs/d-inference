import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

private let calibrationHash = String(repeating: "a", count: 64)
private let calibrationContract = String(repeating: "b", count: 64)

private func calibrationCell() -> DeadlineCalibrationCell {
    .init(promptTokensMin: 1, promptTokensMax: 32_768,
        contextTokensMin: 1, contextTokensMax: 32_768, cacheState: "cold", contention: "isolated",
        prefillTps: 800, decodeTps: 40, maxPrefillWorkTokens: 32_768,
        maxDecodeWorkTokens: 1_024, maxActiveRequests: 1, competitorProfileIds: [],
        maxOtherModelRequests: 0, maxOtherModelServiceFraction: 0,
        errorRatio: 1.12, errorAdditiveMs: 150, calibrationSampleCount: 40,
        validationSampleCount: 40, validationCoveredCount: 39, tailCoverage: 0.95,
        reportSha256: String(repeating: "c", count: 64))
}

func deadlineCalibrationProfileFixture() -> DeadlinePerformanceProfile {
    .init(id: "test-reviewed", modelId: "model", artifactSha256: calibrationHash,
        providerVersion: "test", runtimeRevision: ServingPerformanceProfiles.runtimeRevision,
        kvBackend: "paged", chipName: "Apple M5 Max", gpuCores: 40, memoryGb: 128,
        configuredContextTokens: 32_768, effectiveMaxConcurrency: 4,
        prefillChunkSize: 512, maxConcurrentPartialPrefills: 1,
        mixedPrefillTokenCap: nil, soloPrefillStripeTokens: 4096,
        minimumWholeMacQuiescenceMs: 0, minimumNominalStabilityMs: 5_000, powerMode: "automatic",
        qualificationReportSha256: String(repeating: "c", count: 64),
        deadlineCalibration: .init(version: 1, promptContractId: calibrationContract, cells: [calibrationCell()]))
}

@Test func deadlineCalibrationRequiresHeldOutTailCoverageAndFiniteMeasuredEnvelope() throws {
    let original = deadlineCalibrationProfileFixture()
    #expect(original.isValid)
    let roundTrip = try JSONDecoder().decode(DeadlinePerformanceProfile.self,
        from: JSONEncoder().encode(original))
    #expect(roundTrip == original)
    let mutations: [(inout DeadlineCalibrationCell) -> Void] = [
        { $0.validationSampleCount = 1 }, { $0.calibrationSampleCount = 0 },
        { $0.validationCoveredCount = 37 }, { $0.tailCoverage = 0.90 },
        { $0.errorRatio = 0.9 }, { $0.errorRatio = .infinity },
        { $0.errorAdditiveMs = -1 }, { $0.reportSha256 = "unverified" },
        { $0.competitorProfileIds = ["unmeasured"] }, { $0.maxActiveRequests = 2 }
    ]
    for mutation in mutations {
        var changed = original
        mutation(&changed.deadlineCalibration.cells[0])
        #expect(!changed.isValid)
    }
}

@Test func deadlineCalibrationMTPProfileRequiresExactVerifiedRuntime() {
    let plain = deadlineCalibrationProfileFixture()
    var speculative = plain
    speculative.mtp = .init(enabled: true, artifactSha256: String(repeating: "d", count: 64),
        maxDraftTokens: 3, fixedDraftTokens: nil, maxSpeculativeBatch: 8,
        verificationMode: "automatic", maxAutomaticRectangularTokens: 32)
    let hardware = HardwareInfo(machineModel: "test", chipName: plain.chipName,
        chipFamily: .m5, chipTier: .max, memoryGb: 128, memoryAvailableGb: 100,
        cpuCores: .init(total: 16, performance: 12, efficiency: 4), gpuCores: 40,
        memoryBandwidthGbs: 0)
    func resolve(_ actual: ServingMTPConfiguration?, profiles: [DeadlinePerformanceProfile]) -> DeadlinePerformanceProfile? {
        DeadlinePerformanceProfiles.resolve(modelID: plain.modelId, artifactSHA256: plain.artifactSha256,
            kvBackend: plain.kvBackend, runtime: plain.runtimeConfiguration, hardware: hardware,
            mtp: actual, providerVersion: "test", profiles: profiles)
    }
    #expect(resolve(nil, profiles: [speculative]) == nil)
    #expect(resolve(speculative.mtp, profiles: [plain]) == nil)
    #expect(resolve(speculative.mtp, profiles: [speculative]) == speculative)
    var different = speculative.mtp
    different?.maxDraftTokens = 4
    #expect(resolve(different, profiles: [speculative]) == nil)
    different = speculative.mtp
    different?.artifactSha256 = String(repeating: "e", count: 64)
    #expect(resolve(different, profiles: [speculative]) == nil)
    different = speculative.mtp
    different?.verificationMode = "serial_target"
    #expect(resolve(different, profiles: [speculative]) == nil)
}

@Test func deadlineCalibrationAssistantIdentityUsesVerifiedBytesWithoutRehashing() {
    let url = URL(fileURLWithPath: "/unreadable/not-a-real-assistant")
    let config = String(repeating: "e", count: 64)
    let weights = ["model.safetensors": String(repeating: "f", count: 64)]
    let local = SpecDecArtifact(directory: url, source: .local, revision: "display-only",
        artifactBytes: 1, residentBytes: 1, manifestSHA256: nil,
        localWeightSHA256: weights, localConfigSHA256: config)
    #expect(ServingMTPConfiguration.artifactDigest(local)?.count == 64)
    let incomplete = SpecDecArtifact(directory: url, source: .local, revision: "display-only",
        artifactBytes: 1, residentBytes: 1, manifestSHA256: nil)
    #expect(ServingMTPConfiguration.artifactDigest(incomplete) == nil)
    let inline = SpecDecArtifact(directory: url, source: .inline, revision: "display-only",
        artifactBytes: 1, residentBytes: 1, manifestSHA256: nil, inlineIndexSHA256: config)
    #expect(ServingMTPConfiguration.artifactDigest(inline) == config)
}

@Test func deadlineCalibrationLiveRatesCanOnlyIncreaseTheReviewedTimeBound() {
    let cell = calibrationCell()
    let fasterLive = cell.engineCell(prefillCeiling: 10_000, decodeCeiling: 500)
    #expect(fasterLive.prefillTokensPerSecond == 800)
    #expect(fasterLive.decodeTokensPerSecond == 40)
    let slowerLive = cell.engineCell(prefillCeiling: 500, decodeCeiling: 30)
    #expect(slowerLive.prefillTokensPerSecond == 500)
    #expect(slowerLive.decodeTokensPerSecond == 30)
}

@Test func deadlineCalibrationMatchesActualCountIdentityAndFreshMeasurements() async throws {
    let profile = deadlineCalibrationProfileFixture()
    let budget = GlobalKVCacheBudget(memorySnapshot: {
        .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: 64 << 30)
    }, serviceBudget: deadlineReadyServiceBudgetFixture())
    let bridge = EngineV2Bridge(engine: PrefillScriptEngine(), modelId: profile.modelId,
        tokenizer: TokenizerHandle(CalibrationTokenizer()), eosTokenIds: [],
        deadlineProfile: profile,
        promptWorkIdentity: .init(modelArtifactHash: calibrationHash, promptContractID: calibrationContract),
        kvBudget: budget)
    let now = ContinuousClock.now
    let exact = PromptWork(source: "exact_contract", promptTokens: 8_828, upperBoundTokens: 8_828,
        promptContractID: calibrationContract, modelArtifactHash: calibrationHash)
    await bridge.prepareDeadlineCalibrationTest(now: now)
    let calibrated = await bridge.calibratedDeadlinePolicy(requestID: "target", promptTokens: 8_828,
        promptWork: exact, now: now, allowQualifiedPosture: true)
    #expect(calibrated?.cells.count == 1)
    #expect(calibrated?.evidenceGuard.isValid == true)
    #expect(await bridge.calibratedDeadlinePolicy(requestID: "target", promptTokens: 8_829,
        promptWork: exact, now: now, allowQualifiedPosture: true) == nil)
    #expect(await bridge.calibratedDeadlinePolicy(requestID: "target", promptTokens: 8_828,
        promptWork: exact, now: now.advanced(by: .seconds(121)), allowQualifiedPosture: true) == nil)
    #expect(await bridge.calibratedDeadlinePolicy(requestID: "target", promptTokens: 8_828,
        promptWork: exact, now: now, allowQualifiedPosture: false) == nil)
    var mismatch = exact
    mismatch.promptContractID = String(repeating: "d", count: 64)
    #expect(await bridge.calibratedDeadlinePolicy(requestID: "target", promptTokens: 8_828,
        promptWork: mismatch, now: now, allowQualifiedPosture: true) == nil)
    #expect(await bridge.calibratedDeadlinePolicy(requestID: "target", promptTokens: 8_828,
        promptWork: nil, now: now, allowQualifiedPosture: true) == nil)
    await bridge.releaseServiceAllowance(requestID: "target")
    #expect(calibrated?.evidenceGuard.isValid == false)
    await bridge.shutdown()
}

@Test func deadlineWorkRetainsFullQueuedAndRetiringLeaseBounds() throws {
    let budget = WholeMacServiceBudget()
    #expect(budget.acquire(ownerID: "target", concurrency: 4,
        work: .init(modelID: "model", profileID: "profile", promptTokens: 4_096, maxOutputTokens: 128)))
    let epoch = budget.deadlineWork(modelID: "model", epoch: "model-epoch").epoch
    let snapshot = try #require(budget.calibrationSnapshot(ownerID: "target", modelID: "model", profileID: "profile"))
    #expect(budget.acquire(ownerID: "other", concurrency: 4,
        work: .init(modelID: "other-model", profileID: "other-profile", promptTokens: 16_384, maxOutputTokens: 4_096)))
    #expect(!snapshot.evidenceGuard.isValid)
    let target = budget.deadlineWork(modelID: "model", epoch: "model-epoch")
    #expect(target.known && target.prefillTokens == 4_096 && target.decodeTokens == 128)
    #expect(target.contextTokensMax == 4_224 && target.requestCount == 1 && target.serviceFraction == 0.25)
    let other = budget.deadlineWork(modelID: "other-model", epoch: "other-epoch")
    #expect(other.known && other.prefillTokens == 16_384 && other.decodeTokens == 4_096)
    #expect(other.contextTokensMax == 20_480)
    let competing = try #require(budget.calibrationSnapshot(ownerID: "target", modelID: "model", profileID: "profile"))
    #expect(competing.competitorProfileIDs == ["other-profile"])
    #expect(competing.otherModelRequests == 1 && competing.otherModelServiceFraction == 0.25)
    budget.release(ownerID: "other")
    #expect(!competing.evidenceGuard.isValid)
    #expect(budget.deadlineWork(modelID: "model", epoch: "model-epoch").epoch == epoch)
    budget.release(ownerID: "target")
    #expect(budget.deadlineWork(modelID: "model", epoch: "model-epoch").requestCount == 0)
    #expect(budget.acquire(ownerID: "unrepresented", concurrency: 4))
    #expect(!budget.deadlineWork(modelID: "model", epoch: "model-epoch").known)
    budget.release(ownerID: "unrepresented")
}

@Test func deadlineWorkAndReservationCorrelationShareOneImmutableSnapshot() throws {
    let budget = WholeMacServiceBudget()
    let oldID = "6e1f61d1-e22c-4d24-a3a7-d347772a48cb"
    let newID = "9b3f32a9-3d08-4a71-b70a-dd5a2b2f140f"
    #expect(budget.acquire(ownerID: "old", concurrency: 4, serviceReservationID: oldID,
        work: .init(modelID: "model", profileID: "profile", promptTokens: 1_024, maxOutputTokens: 128)))
    let before = budget.snapshot(slotEpochs: ["model": "epoch"], profileIDs: ["model": "profile"])
    budget.release(ownerID: "old")
    #expect(budget.acquire(ownerID: "new", concurrency: 4, serviceReservationID: newID,
        work: .init(modelID: "model", profileID: "profile", promptTokens: 16_384, maxOutputTokens: 128)))
    let after = budget.snapshot(slotEpochs: ["model": "epoch"], profileIDs: ["model": "profile"])
    #expect(before.usedFraction == after.usedFraction)
    #expect(before.reservations.first?.id == oldID && before.deadlineWorkByModel["model"]?.prefillTokens == 1_024)
    #expect(after.reservations.first?.id == newID && after.deadlineWorkByModel["model"]?.prefillTokens == 16_384)
    let replacedRuntime = budget.snapshot(slotEpochs: ["model": "new-epoch"], profileIDs: ["model": "new-profile"])
    #expect(replacedRuntime.deadlineWorkByModel["model"]?.known == false)
    budget.release(ownerID: "new")
}

@Test func deadlineCalibrationRejectsOutOfContextCompetitorsBeforeSubmissionValidation() async throws {
    let targetProfile = deadlineCalibrationProfileFixture()
    var otherProfile = targetProfile
    otherProfile.id = "other-profile"
    otherProfile.modelId = "other-model"
    otherProfile.configuredContextTokens = 4_096
    otherProfile.deadlineCalibration.cells[0].promptTokensMax = 4_096
    otherProfile.deadlineCalibration.cells[0].contextTokensMax = 4_096
    let budget = GlobalKVCacheBudget(memorySnapshot: {
        .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: 64 << 30)
    }, serviceBudget: deadlineReadyServiceBudgetFixture())
    let target = EngineV2Bridge(engine: PrefillScriptEngine(), modelId: targetProfile.modelId,
        tokenizer: TokenizerHandle(CalibrationTokenizer()), eosTokenIds: [],
        deadlineProfile: targetProfile, kvBudget: budget)
    let other = EngineV2Bridge(engine: PrefillScriptEngine(), modelId: otherProfile.modelId,
        tokenizer: TokenizerHandle(CalibrationTokenizer()), eosTokenIds: [],
        deadlineProfile: otherProfile, kvBudget: budget)
    #expect(await target.acquireServiceAllowance(requestID: "target", promptTokens: 128,
        maxOutputTokens: 32, allowExpansion: true))
    let ownerID = await target.serviceOwnerPrefix + ":target"
    func snapshot() -> WholeMacServiceBudget.CalibrationSnapshot? {
        budget.serviceBudget.calibrationSnapshot(ownerID: ownerID,
            modelID: targetProfile.modelId, profileID: targetProfile.id)
    }
    #expect(snapshot() != nil)
    // Hold each competitor at the pre-submit ownership boundary, before the
    // later context guard can refuse it. Its physical service charge remains.
    for (prompt, output) in [(4_090, 7), (4_097, 0), (1, Int.max), (Int.max, 1)] {
        #expect(await other.acquireServiceAllowance(requestID: "competitor", promptTokens: prompt,
            maxOutputTokens: output, allowExpansion: true))
        #expect(abs(budget.serviceBudget.usedFraction - 2.0 / 24.0) < 1e-12)
        #expect(snapshot() == nil)
        await other.releaseServiceAllowance(requestID: "competitor")
        #expect(snapshot() != nil)
    }
    #expect(await other.acquireServiceAllowance(requestID: "competitor", promptTokens: 4_090,
        maxOutputTokens: 6, allowExpansion: true))
    let withinContext = try #require(snapshot())
    #expect(withinContext.competitorProfileIDs == [otherProfile.id])
    #expect(withinContext.otherModelPrefillTokens == 4_090)
    #expect(withinContext.otherModelDecodeTokens == 6)
    await other.releaseServiceAllowance(requestID: "competitor")
    await target.releaseServiceAllowance(requestID: "target")
    await other.shutdown()
    await target.shutdown()
}

private extension EngineV2Bridge {
    func prepareDeadlineCalibrationTest(now: ContinuousClock.Instant) {
        for (name, rate) in [("isolated_prefill", 1_000.0), ("decode", 60.0)] {
            performanceMeasurements.observe(name, tps: rate, prompt: 8_828, context: 8_828,
                cache: "cold", overlap: .init(), at: now)
        }
        #expect(acquireServiceAllowance(requestID: "target", promptTokens: 8_828,
            maxOutputTokens: 4_096, allowExpansion: true))
    }
}

private struct CalibrationTokenizer: MLXLMCommon.Tokenizer {
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

@Test func deadlineCalibrationNarrowCellsDoNotRequireUniversalPolicyOrIncomingOutputCompletion() async throws {
    var profile = deadlineCalibrationProfileFixture()
    profile.configuredContextTokens = 262_144
    profile.deadlineCalibration.cells[0].promptTokensMax = 4096
    profile.deadlineCalibration.cells[0].contextTokensMax = 4096
    profile.deadlineCalibration.cells[0].maxPrefillWorkTokens = 4096
    #expect(profile.isValid)
    let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
    for forbidden in ["max_concurrency", "whole_mac_concurrency", "batch_curve"] {
        #expect(json[forbidden] == nil)
    }
    let budget = GlobalKVCacheBudget(memorySnapshot: {
        .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: 64 << 30)
    }, serviceBudget: deadlineReadyServiceBudgetFixture())
    let bridge = EngineV2Bridge(engine: PrefillScriptEngine(), modelId: profile.modelId,
        tokenizer: TokenizerHandle(CalibrationTokenizer()), eosTokenIds: [],
        deadlineProfile: profile,
        promptWorkIdentity: .init(modelArtifactHash: calibrationHash, promptContractID: calibrationContract),
        kvBudget: budget)
    let now = ContinuousClock.now
    await bridge.prepareNarrowDeadlineCalibrationTest(now: now)
    #expect(bridge.performanceProfile == nil)
    #expect(await bridge.effectiveServingConcurrency(allowExpansion: true) == 4)
    #expect(abs(budget.serviceBudget.usedFraction - 1.0 / 24.0) < 1e-12)
    let work = PromptWork(source: "exact_contract", promptTokens: 4000, upperBoundTokens: 4000,
        promptContractID: calibrationContract, modelArtifactHash: calibrationHash)
    let policy = try #require(await bridge.calibratedDeadlinePolicy(requestID: "target", promptTokens: 4000,
        promptWork: work, now: now, allowQualifiedPosture: true))
    #expect(policy.cells.count == 1)
    // Its own 32k output reservation does not enter the first-content bound.
    // For every later request, the retained original bound is existing work.
    #expect(!budget.serviceBudget.deadlineWork(modelID: profile.modelId, epoch: "fixture").known)
    #expect(await bridge.acquireServiceAllowance(requestID: "next", promptTokens: 100,
        maxOutputTokens: 100, allowExpansion: true))
    let nextOwner = await bridge.serviceOwnerPrefix + ":next"
    #expect(budget.serviceBudget.calibrationSnapshot(ownerID: nextOwner,
        modelID: profile.modelId, profileID: profile.id) == nil)
    await bridge.releaseServiceAllowance(requestID: "next")
    await bridge.releaseServiceAllowance(requestID: "target")
    await bridge.shutdown()
}

@Test func deadlineCalibrationRequiresExactEffectiveRuntimeAndOnDemandArtifactIdentity() throws {
    let profile = deadlineCalibrationProfileFixture()
    let hardware = HardwareInfo(machineModel: "test", chipName: profile.chipName,
        chipFamily: .m5, chipTier: .max, memoryGb: 128, memoryAvailableGb: 100,
        cpuCores: .init(total: 16, performance: 12, efficiency: 4), gpuCores: 40, memoryBandwidthGbs: 0)
    func resolve(_ runtime: DeadlineRuntimeConfiguration, hash: String? = calibrationHash,
        environment: [String: String] = [:]) -> DeadlinePerformanceProfile? {
        DeadlinePerformanceProfiles.resolve(modelID: profile.modelId, artifactSHA256: hash,
            kvBackend: profile.kvBackend, runtime: runtime, hardware: hardware,
            environment: environment, providerVersion: "test", profiles: [profile])
    }
    #expect(resolve(profile.runtimeConfiguration) == profile)
    #expect(resolve(profile.runtimeConfiguration, hash: nil) == nil)
    #expect(DeadlinePerformanceProfiles.requiresArtifactHash(modelID: profile.modelId, profiles: [profile]))
    #expect(!DeadlinePerformanceProfiles.requiresArtifactHash(modelID: "other", profiles: [profile]))
    let mutations: [(inout DeadlineRuntimeConfiguration) -> Void] = [
        { $0.configuredContextTokens -= 1 }, { $0.effectiveMaxConcurrency = 8 },
        { $0.prefillChunkSize = 256 }, { $0.maxConcurrentPartialPrefills = 2 },
        { $0.mixedPrefillTokenCap = 128 }, { $0.soloPrefillStripeTokens = nil }
    ]
    for mutate in mutations {
        var runtime = profile.runtimeConfiguration
        mutate(&runtime)
        #expect(resolve(runtime) == nil)
    }
    #expect(resolve(profile.runtimeConfiguration, environment: ["DARKBLOOM_CBV2_SOLO_PREFILL_STRIPE": "4096"]) == nil)
}

private extension EngineV2Bridge {
    func prepareNarrowDeadlineCalibrationTest(now: ContinuousClock.Instant) {
        for (name, rate) in [("isolated_prefill", 1_000.0), ("decode", 60.0)] {
            performanceMeasurements.observe(name, tps: rate, prompt: 4000, context: 4000,
                cache: "cold", overlap: .init(), at: now)
        }
        #expect(acquireServiceAllowance(requestID: "target", promptTokens: 4000,
            maxOutputTokens: 32_768, allowExpansion: true))
    }
}
