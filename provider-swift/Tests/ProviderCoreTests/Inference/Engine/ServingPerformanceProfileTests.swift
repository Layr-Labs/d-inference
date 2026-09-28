import Foundation
import Testing
import MLXLMCommon
@testable import ProviderCore

private func measuredProfileFixture() -> ServingPerformanceProfile {
    .init(id: "test-only-ultra", modelId: "model", artifactSha256: String(repeating: "a", count: 64),
          providerVersion: "test", runtimeRevision: ServingPerformanceProfiles.runtimeRevision,
          kvBackend: "paged", chipName: "Apple M5 Ultra", gpuCores: 80, memoryGb: 192,
          contextTokensMax: 32768, maxConcurrency: 16, wholeMacConcurrency: 16,
          mixedPrefillTokenCap: 512, qualificationReportSha256: String(repeating: "b", count: 64),
          batchCurve: [.init(width: 1, decodeP10Tps: 90, aggregateDecodeTps: 100,
                             prefillTps: 6000, firstContentP95Ms: 1200),
                       .init(width: 16, decodeP10Tps: 35, aggregateDecodeTps: 700,
                             prefillTps: 6000, firstContentP95Ms: 2800)])
}

@Test func servingPerformanceProfileRequiresEveryExactIdentity() throws {
    let profile = measuredProfileFixture()
    let hardware = HardwareInfo(machineModel: "test", chipName: profile.chipName,
                                chipFamily: .m5, chipTier: .ultra, memoryGb: 192,
                                memoryAvailableGb: 160, cpuCores: .init(total: 32, performance: 24, efficiency: 8),
                                gpuCores: 80, memoryBandwidthGbs: 0)
    func resolve(hash: String? = profile.artifactSha256, backend: String = "paged",
                 context: Int? = 32768, version: String = "test", machine: HardwareInfo = hardware)
        -> ServingPerformanceProfile? {
        ServingPerformanceProfiles.resolve(modelID: "model", artifactSHA256: hash,
            kvBackend: backend, contextTokens: context, hardware: machine,
            providerVersion: version, profiles: [profile])
    }
    #expect(resolve()?.maxConcurrency == 16)
    #expect(resolve(hash: nil) == nil)
    #expect(resolve(hash: String(repeating: "c", count: 64)) == nil)
    #expect(resolve(backend: "contiguous") == nil)
    #expect(resolve(context: 32769) == nil)
    #expect(resolve(context: nil) == nil)
    #expect(resolve(version: "next-release") == nil)
    var smaller = hardware
    smaller.gpuCores = 64
    #expect(resolve(machine: smaller) == nil)
    smaller = hardware
    smaller.memoryGb = 128
    #expect(resolve(machine: smaller) == nil)
    #expect(ServingPerformanceProfiles.concurrency(configured: 16) == 8)
    #expect(ServingPerformanceProfiles.concurrency(configured: 16, profile: profile) == 16)
    #expect(ServingPerformanceProfiles.concurrency(configured: 2, profile: profile) == 2)
    var invalid = profile
    invalid.batchCurve[1].decodeP10Tps = 29
    #expect(ServingPerformanceProfiles.concurrency(configured: 16, profile: invalid) == 8)
    let encoded = try JSONEncoder().encode(profile)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["artifact_sha256"] as? String == profile.artifactSha256)
    #expect(try JSONDecoder().decode(ServingPerformanceProfile.self, from: encoded) == profile)
}

@Test func servingProfileArtifactVerificationDoesNotDependOnPrefixCachePolicy() {
    let profile = measuredProfileFixture()
    let hardware = HardwareInfo(machineModel: "test", chipName: profile.chipName,
        chipFamily: .m5, chipTier: .ultra, memoryGb: 192, memoryAvailableGb: 160,
        cpuCores: .init(total: 32, performance: 24, efficiency: 8), gpuCores: 80,
        memoryBandwidthGbs: 0)
    for environment in [[String: String](), ["DARKBLOOM_PREFIX_CACHE": "0"]] {
        // The fixture is outside the default SSD cohort, and an explicit
        // cache kill switch must likewise leave profile identity available.
        #expect(!PrefixCachePolicy.isEnabled(modelId: profile.modelId, environment: environment))
        #expect(ServingPerformanceProfiles.runtimeOverridesAreAbsent(environment))
        #expect(ServingPerformanceProfiles.requiresArtifactHash(modelID: profile.modelId, profiles: [profile]))
        let resolved = ServingPerformanceProfiles.resolve(modelID: profile.modelId,
            artifactSHA256: profile.artifactSha256, kvBackend: "paged", contextTokens: 32768,
            hardware: hardware, environment: environment, providerVersion: "test", profiles: [profile])
        #expect(resolved?.maxConcurrency == 16)
    }
    #expect(ServingPerformanceProfiles.resolve(modelID: profile.modelId,
        artifactSHA256: profile.artifactSha256, kvBackend: "paged", contextTokens: 32768,
        hardware: hardware, environment: [MixedPrefillPolicy.globalKey: "128"],
        providerVersion: "test", profiles: [profile]) == nil)
    #expect(!ServingPerformanceProfiles.requiresArtifactHash(modelID: "unreviewed", profiles: [profile]))
    #expect(!ServingPerformanceProfiles.requiresArtifactHash(modelID: profile.modelId, profiles: []))
}

@Test func servingPerformanceDefaultsPreserveOperatorIntentAcrossSerialization() throws {
    let missing = try JSONDecoder().decode(BackendSettings.self, from: Data("{}".utf8))
    #expect(!missing.engineV2MaxConcurrentIsExplicit)
    let automatic = try JSONDecoder().decode(BackendSettings.self, from: JSONEncoder().encode(missing))
    #expect(!automatic.engineV2MaxConcurrentIsExplicit)
    let explicit = BackendSettings(engineV2MaxConcurrent: 4)
    let restored = try JSONDecoder().decode(BackendSettings.self, from: JSONEncoder().encode(explicit))
    #expect(restored.engineV2MaxConcurrentIsExplicit)
    #expect(restored.engineV2MaxConcurrent == 4)
    var changed = missing
    changed.engineV2MaxConcurrent = 2
    #expect(changed.engineV2MaxConcurrentIsExplicit)
}

@Test func mixedPrefillIsPerModelAndPreservesGemmaEfficientFloor() {
    let env = [MixedPrefillPolicy.modelKey: "gemma-4-26b=64,other=256", MixedPrefillPolicy.globalKey: "512"]
    #expect(MixedPrefillPolicy.resolve(modelID: "gemma-4-26b", profile: nil, environment: env) == 128)
    #expect(MixedPrefillPolicy.resolve(modelID: "other", profile: nil, environment: env) == 256)
    #expect(MixedPrefillPolicy.resolve(modelID: "third", profile: nil, environment: env) == 512)
    #expect(MixedPrefillPolicy.resolve(modelID: "renamed-model", profile: nil,
        environment: [MixedPrefillPolicy.globalKey: "64"], requiresNarrowingFloor: true) == 128)
    let a = SchedulerV2(config: .init(mixedStepPrefillTokenCap: 128))
    let b = SchedulerV2(config: .init(mixedStepPrefillTokenCap: 512))
    #expect(a.mixedStepPrefillTokenCap == 128)
    #expect(b.mixedStepPrefillTokenCap == 512)
    #expect(!ServingPerformanceProfiles.runtimeOverridesAreAbsent(env))
}

@Test func wholeMacServiceAllowanceIsSharedAndRetiresOnlyOwnedLeases() {
    let budget = WholeMacServiceBudget()
    DispatchQueue.concurrentPerform(iterations: 48) { index in
        _ = budget.acquire(ownerID: "model-\(index % 3):request-\(index)", concurrency: 16)
    }
    #expect(budget.count == 16)
    #expect(abs(budget.usedFraction - 1) < 1e-12)
    budget.release(ownerID: "not-an-owner")
    #expect(!budget.acquire(ownerID: "more", concurrency: 16))
    for index in 0..<48 { budget.release(ownerID: "model-\(index % 3):request-\(index)") }
    #expect(budget.count == 0)
    #expect(budget.acquire(ownerID: "slow", concurrency: 2))
    for index in 0..<8 { #expect(budget.acquire(ownerID: "fast-\(index)", concurrency: 16)) }
    #expect(!budget.acquire(ownerID: "over", concurrency: 16))
}

@Test func servingPerformanceContextRejectsActualPromptAndReservedOutputBeforeAdmission() async throws {
    let profile = measuredProfileFixture()
    for (prompt, output) in [(32768, 1), (32767, 2), (1, Int.max)] {
        let engine = ProfileContextSentinelEngine()
        let budget = GlobalKVCacheBudget(memorySnapshot: {
            .init(total: 64 << 30, active: 0, cache: 0, systemAvailable: 64 << 30)
        })
        let bridge = EngineV2Bridge(engine: engine, modelId: "generic-model",
            tokenizer: TokenizerHandle(ProfileContextTokenizer()), eosTokenIds: [],
            maxConcurrentRequests: 16, performanceProfile: profile, kvBudget: budget)
        do {
            _ = try await bridge.submitTokenized(promptTokens: Array(repeating: 1, count: prompt),
                request: .init(model: "generic-model", messages: [], max_tokens: output),
                requestId: "outside-profile-context", firstContentDeadline: nil)
            Issue.record("out-of-profile context reached engine admission")
        } catch let error as MultiModelBatchSchedulerEngineError {
            #expect(error == .advertisedContextExceeded)
        }
        #expect(engine.submissions == 0)
        #expect(budget.serviceBudget.count == 0)
        #expect(await bridge._testPendingSubmissionCount() == 0)
        await bridge.shutdown()
    }
}

private final class ProfileContextSentinelEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var submitted = 0
    var submissions: Int { lock.withLock { submitted } }
    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        lock.withLock { submitted += 1 }
        return AsyncStream { $0.finish() }
    }
    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        .init(activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0, kvBytesCapacity: 0, activeTokens: 0)
    }
    func shutdown() async {}
}

private struct ProfileContextTokenizer: MLXLMCommon.Tokenizer {
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
