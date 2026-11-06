import DarkbloomClusterProtocol
import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// A pair's slot reports what a single Mac's reports: dated prefill and decode
/// measurements from the requests it served, and the request sizes it serves.
/// Without them the coordinator's first-content forecast of a pair stayed
/// `unknown` all day in production (11-05), so a pair never stood beside a
/// feasible single Mac even for a long prompt. Fabricated owners only.
@Suite("Pair slot measurements and request limits", .serialized, .timeLimit(.minutes(1)))
struct DistributedPairMeasurementTests {
    /// The engine's terminal usage carries the request's timing in the engine
    /// contract's terms, and its prompt observation reaches the bridge once,
    /// at the clean finish, with the reuse the ranks reported.
    @Test func aCleanFinishReportsTheRequestsTimingAndItsPromptObservation() async throws {
        let clock = DistributedTestClock()
        let owner = DistributedTestOwner()
        owner.onReserve = { clock.advance(.milliseconds(250)) } // both ranks reserving
        let engine = try distributedTestEngine(owner, clock: clock.clock)
        let observed = UsageObservations()
        var request = distributedTestRequest(1, maxTokens: 3)
        request.onPrefillCompleted = { observed.record($0) }
        let stream = try engine.submit(request)
        let lease = owner.last
        clock.advance(.seconds(2)) // the prompt
        #expect(lease.send(.token(4)))
        clock.advance(.milliseconds(400))
        #expect(lease.send(.token(5)))
        clock.advance(.milliseconds(600))
        #expect(!lease.send(.token(6)))
        #expect(observed.values.isEmpty, "the prompt is reported once its reuse is known")
        lease.acknowledge()
        let events = await distributedCollect(stream)
        let usage = try #require(distributedTerminal(events)?.1)
        let timing = usage.timing
        #expect(timing.admittedNanos == 250_000_000 && timing.prefillFirstLaunchNanos == 250_000_000)
        #expect(timing.promptComputedNanos == 2_250_000_000 && timing.firstTokenNanos == timing.promptComputedNanos)
        #expect(timing.lastTokenNanos == 3_250_000_000)
        #expect(timing.decodeSteps == 2)
        #expect(timing.lastTokenUptimeNanos > 0 && timing.lastTokenUptimeNanos <= DispatchTime.now().uptimeNanoseconds)
        #expect(timing.visionChunks == 0)
        // The bridge's own arithmetic on it: 3 prompt tokens over 2 s, 2 tokens over 1 s.
        #expect(EngineV2NativeBlockTiming.prefillSeconds(timing) == 2)
        #expect(EngineV2Bridge.engineDecodeRate(usage: usage, nativeBlock: false) == 2)
        #expect(observed.values.count == 1)
        #expect(observed.values.first?.timing == timing)
        #expect(observed.values.first.map { EngineV2Bridge.isColdPrefillSample(usage: $0) } == true)
        await engine.shutdown()
    }

    /// A prompt both ranks partly restored is reported as reused, never as a
    /// cold prompt the pair computed in full.
    @Test func aRestoredPromptIsReportedWithItsReuse() async throws {
        let owner = DistributedTestOwner()
        let engine = try distributedTestEngine(owner)
        let observed = UsageObservations()
        var request = distributedTestRequest(1, maxTokens: 1)
        request.onPrefillCompleted = { observed.record($0) }
        let stream = try engine.submit(request)
        let lease = owner.last
        #expect(!lease.send(.token(4)))
        lease.send(.promptCache(reused: 2, stored: []))
        lease.acknowledge()
        _ = await distributedCollect(stream)
        let reported = try #require(observed.values.first)
        #expect(reported.prefixCachePrefillTokensSaved == 2 && reported.prefixCacheOutcome == .hit)
        #expect(!EngineV2Bridge.isColdPrefillSample(usage: reported))
        await engine.shutdown()
    }

    /// A request that failed has no prompt observation: its ranks may never
    /// have reported what they restored.
    @Test func aFailedRequestReportsNoPromptObservation() async throws {
        let owner = DistributedTestOwner()
        let engine = try distributedTestEngine(owner)
        let observed = UsageObservations()
        var request = distributedTestRequest(1, maxTokens: 3)
        request.onPrefillCompleted = { observed.record($0) }
        let stream = try engine.submit(request)
        let lease = owner.last
        #expect(lease.send(.token(4)))
        owner.losePeer()
        lease.acknowledge()
        let events = await distributedCollect(stream)
        guard case .error? = distributedTerminal(events)?.0 else {
            Issue.record("a lost peer fails the request: \(String(describing: distributedTerminal(events)?.0))")
            return
        }
        #expect(observed.values.isEmpty)
        await engine.shutdown()
    }

    @Test func theRequestLimitsAreTheProfilesAndWhatBothRanksAdmitNow() throws {
        let owner = DistributedTestOwner()
        let engine = try distributedTestEngine(owner)
        #expect(engine.requestLimits() == SlotRequestLimits(maxPromptTokens: 8192, maxOutputTokens: 128,
                                                            maxContextTokens: 8320, servingContextTokens: nil))
        owner.servingContextTokens = 4096
        #expect(engine.requestLimits().servingContextTokens == 4096)
        // Never above the profile's context, whatever a rank states.
        owner.servingContextTokens = 100_000
        #expect(engine.requestLimits().servingContextTokens == 8320)
        owner.losePeer(notify: false)
        #expect(engine.requestLimits().servingContextTokens == nil)
    }

    /// A row with a native context beyond the standard request (GLM-5.3-Flash's
    /// limits; Qwen3.8 27B's work the same way) serves it in tensor parallel
    /// only: a pipeline's ranks refuse a reservation beyond the memory plan's
    /// request. The pipeline's leader refuses such a request itself, and its
    /// slot reports what it serves, so the coordinator never sends one.
    @Test func aPipelinePairHoldsAndReportsItsMemoryPlansRequest() throws {
        func hash(_ c: Character) -> String { String(repeating: String(c), count: 64) }
        let capability = try ClusterRuntimeCapability(runtimeBinarySHA256: hash("a"),
            adapterID: ClusterRuntimeAdapter.glm5NextLayerStage.rawValue, adapterVersion: 1,
            runtimeModelID: "registered_glm53_flash", artifactSHA256: hash("b"), configurationSHA256: hash("c"),
            manifestSHA256: hash("d"),
            profile: .init(id: "registered_glm53_flash_greedy_generation_v1", vocabularySize: 154_880,
                maximumPromptTokens: 1_048_575, maximumOutputTokens: 65_536, maximumChunkTokens: 2048,
                maximumContextTokens: 1_048_576),
            profileFingerprint: hash("e"), partitions: [.init(planSHA256: hash("f"), stages: [
                .init(rank: 0, sourceLayerStart: 0, sourceLayerEnd: 1, stagePlanSHA256: hash("1"), constructionConfigurationSHA256: hash("2")),
                .init(rank: 1, sourceLayerStart: 1, sourceLayerEnd: 2, stagePlanSHA256: hash("3"), constructionConfigurationSHA256: hash("4"))])],
            arithmeticPolicyID: ClusterRuntimeAdapter.glm5NextLayerStage.arithmeticPolicyID, arithmeticPolicySHA256: hash("5"),
            supportedGenerationModes: [.pipeline, .tensorParallel])
        let owner = DistributedTestOwner()
        owner.profileID = capability.profile.id
        func engine(_ mode: ClusterGenerationMode) throws -> DistributedCBv2Engine {
            try DistributedCBv2Engine(owner: owner, expectedIdentity: owner.identity,
                profile: .init(capability: capability, generationMode: mode, requestTimeout: .seconds(315)),
                detokenizers: DistributedTestDetokenizers())
        }
        let pipeline = try engine(.pipeline), tensor = try engine(.tensorParallel)
        #expect(pipeline.requestLimits() == SlotRequestLimits(maxPromptTokens: 32_768, maxOutputTokens: 32_768,
                                                              maxContextTokens: 65_536))
        #expect(tensor.requestLimits() == SlotRequestLimits(maxPromptTokens: 1_048_575, maxOutputTokens: 65_536,
                                                            maxContextTokens: 1_048_576))
        // The wire profile both ranks' READY carries is unchanged.
        #expect(pipeline.profile.maxPromptTokens == 1_048_575 && pipeline.profile.maxOutputTokens == 65_536)
        let longOutput = distributedTestRequest(1, maxTokens: 40_000)
        let longPrompt = CBv2Request(id: .init(2), promptTokens: Array(repeating: 1, count: 40_000),
                                     sampling: .init(temperature: 0), maxTokens: 1)
        #expect(pipeline.profile.refusal(for: longOutput) == .outputTooLong)
        #expect(pipeline.profile.refusal(for: longPrompt) == .promptTooLong)
        #expect(DistributedRequestRefusal.outputTooLong.message(pipeline.profile)
            == "max_tokens is above this model's output limit of 32768 tokens on this cluster.")
        #expect(tensor.profile.refusal(for: longOutput) == nil && tensor.profile.refusal(for: longPrompt) == nil)
    }

    /// End to end through the provider bridge: one served request becomes the
    /// slot's measured isolated prefill and decode, dated, with the pair's
    /// request limits beside them.
    @Test func aServedPairRequestBecomesTheSlotsMeasuredRates() async throws {
        let owner = DistributedTestOwner()
        owner.servingContextTokens = 6000
        let bridge = try DistributedEngineFactory.makeBridge(
            owner: owner, expectedIdentity: owner.identity, profile: distributedTestProfile(),
            tokenizer: TokenizerHandle(DistributedTestTokenizer()), eosTokenIDs: [99])
        let before = await bridge.backendSlotCapacity()
        #expect(before.performanceMeasurements?.isolatedPrefill == nil && before.performanceMeasurements?.decode == nil)
        #expect(before.requestLimits == SlotRequestLimits(maxPromptTokens: 8192, maxOutputTokens: 128,
                                                          maxContextTokens: 8320, servingContextTokens: 6000))
        let stream = await bridge.submitTokenized(
            promptTokens: Array(repeating: 1, count: 512),
            request: ChatCompletionRequest(model: owner.identity.modelID, messages: [], temperature: 0, max_tokens: 3),
            requestId: "pair-measured-request", cacheEnabled: false)
        try #require(owner.reserveCount == 1)
        let lease = owner.last
        try await Task.sleep(for: .milliseconds(60))
        lease.send(.token(4))
        try await Task.sleep(for: .milliseconds(30))
        lease.send(.token(5))
        try await Task.sleep(for: .milliseconds(30))
        lease.send(.token(6))
        lease.acknowledge()
        for await _ in stream {}
        let after = await bridge.backendSlotCapacity()
        let measured = try #require(after.performanceMeasurements)
        let prefill = try #require(measured.isolatedPrefill)
        let decode = try #require(measured.decode)
        #expect(prefill.sampleCount == 1 && decode.sampleCount == 1)
        #expect(prefill.tokensPerSecond > 0 && prefill.tokensPerSecond <= 512 / 0.06)
        #expect(decode.tokensPerSecond > 0 && decode.tokensPerSecond <= 2 / 0.06)
        #expect(prefill.sampleAgeMs >= 0 && decode.sampleAgeMs >= 0)
        #expect(after.observedDecodeTps > 0)
        #expect(after.telemetry?.ewmaInitialized == true && (after.telemetry?.isolatedPrefillTps ?? 0) > 0)
        #expect(after.requestLimits?.servingContextTokens == 6000)
        await bridge.shutdown()
    }

    /// A prompt that ran alone is an isolated prompt even when another request
    /// joins its decode, and it is dated at its first committed token. The
    /// ranks report what they restored only at the finish, so the bridge fixes
    /// the prompt's overlap and date when its first token arrives. Before, a
    /// prompt was filed as contended whenever anything overlapped its decode,
    /// and dated at the finish, so a busy cluster's prompts read as fast.
    @Test func aPromptThatRanAloneIsIsolatedEvenIfAnotherRequestJoinsItsDecode() async throws {
        let owner = DistributedTestOwner()
        owner.lanes = 2
        let bridge = try DistributedEngineFactory.makeBridge(
            owner: owner, expectedIdentity: owner.identity, profile: distributedTestProfile(),
            tokenizer: TokenizerHandle(DistributedTestTokenizer()), eosTokenIDs: [99])
        let alone = await bridge.submitTokenized(
            promptTokens: Array(repeating: 1, count: 512),
            request: ChatCompletionRequest(model: owner.identity.modelID, messages: [], temperature: 0, max_tokens: 3),
            requestId: "prompt-alone", cacheEnabled: false)
        try #require(owner.reserveCount == 1)
        let first = owner.lease(0)
        try await Task.sleep(for: .milliseconds(60))
        first.send(.token(4)) // its whole prompt ran alone
        try await Task.sleep(for: .milliseconds(20))
        let joined = await bridge.submitTokenized(
            promptTokens: Array(repeating: 1, count: 256),
            request: ChatCompletionRequest(model: owner.identity.modelID, messages: [], temperature: 0, max_tokens: 2),
            requestId: "joins-the-decode", cacheEnabled: false)
        try #require(owner.reserveCount == 2)
        let second = owner.lease(1)
        try await Task.sleep(for: .milliseconds(150)) // a decode beside the second request
        first.send(.token(5))
        first.send(.token(6))
        first.acknowledge()
        for await _ in alone {}
        let capacity = await bridge.backendSlotCapacity()
        let measured = try #require(capacity.performanceMeasurements)
        let prefill = try #require(measured.isolatedPrefill,
            "a prompt that ran alone was filed as \(String(describing: measured.contendedPrefill))")
        #expect(measured.contendedPrefill == nil)
        #expect(prefill.sampleCount == 1)
        // Dated at its first token, before the 150 ms of decode, not at the finish.
        #expect(prefill.sampleAgeMs >= 150)
        second.send(.token(4))
        second.send(.token(5))
        second.acknowledge()
        for await _ in joined {}
        await bridge.shutdown()
    }

    /// The pair's warmup canary measures first use, not the pair's speed: its
    /// few tokens never become the slot's rates.
    @Test func theWarmupCanaryNeverBecomesTheSlotsRates() async throws {
        let owner = DistributedTestOwner()
        let bridge = try DistributedEngineFactory.makeBridge(
            owner: owner, expectedIdentity: owner.identity, profile: distributedTestProfile(),
            tokenizer: TokenizerHandle(DistributedTestTokenizer()), eosTokenIDs: [99])
        let canary = Task { await ProviderLoop.runClusterPairWarmup(bridge: bridge, modelID: owner.identity.modelID, timeoutSeconds: 30) }
        while owner.reserveCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        let lease = owner.last
        try await Task.sleep(for: .milliseconds(20))
        for token in 4..<(4 + ProviderLoop.clusterWarmupMaxTokens) {
            lease.send(.token(token))
            try await Task.sleep(for: .milliseconds(5))
        }
        lease.acknowledge()
        let result = await canary.value
        #expect(result.succeeded, "\(result)")
        let capacity = await bridge.backendSlotCapacity()
        #expect(capacity.performanceMeasurements?.isolatedPrefill == nil)
        #expect(capacity.performanceMeasurements?.decode == nil)
        #expect(capacity.observedDecodeTps == 0)
        await bridge.shutdown()
    }

    @Test func aChangedServingContextIsAMaterialCapacityChange() {
        func capacity(_ serving: Int?) -> BackendCapacity {
            BackendCapacity(slots: [BackendSlotCapacity(model: "pair", state: "idle", numRunning: 0, numWaiting: 0,
                activeTokens: 0, maxTokensPotential: 0,
                requestLimits: .init(maxPromptTokens: 262_143, maxOutputTokens: 65_536, maxContextTokens: 262_144,
                                     servingContextTokens: serving))],
                gpuMemoryActiveGb: 0, gpuMemoryPeakGb: 0, gpuMemoryCacheGb: 0, totalMemoryGb: 256, freeForLoadGb: 0)
        }
        #expect(!CapacityHeartbeatMateriality.isMaterial(previous: capacity(262_144), current: capacity(262_144)))
        #expect(CapacityHeartbeatMateriality.isMaterial(previous: capacity(262_144), current: capacity(180_000)))
        #expect(CapacityHeartbeatMateriality.isMaterial(previous: capacity(nil), current: capacity(180_000)))
    }
}

private final class UsageObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [CBv2Usage] = []
    func record(_ usage: CBv2Usage) { lock.withLock { recorded.append(usage) } }
    var values: [CBv2Usage] { lock.withLock { recorded } }
}
