import Foundation
import Testing
@testable import ProviderCore

@Suite("GPT-OSS mixed-suffix prefix caching (live)", .serialized)
struct GPTOSSMixedPrefixCacheLiveTests {
    @Test("B2/B4 restored branches and simultaneous hits/misses retain request-local answers",
          .timeLimit(.minutes(10)),
          .enabled(if: LiveInferenceFixtures.liveTestsEnabled
            && ProcessInfo.processInfo.environment["DARKBLOOM_LIVE_MLX_GPTOSS_MIXED_PREFIX"] == "1"))
    func concurrentSuffixesRemainIsolated() async throws {
        // Strict synthetic precision tests run separately. This fixture keeps
        // the runtime's ordinary M5 numerical paths for release qualification.
        try #require(ProcessInfo.processInfo.environment["MLX_ENABLE_TF32"] == nil,
                     "run the real-model mixed gate with production TF32 defaults")
        let fixture = try await GPTOSSCheckpointRestartFixture()
        do {
            typealias Request = GPTOSSMixedPrefixCohort.Request
            let first = Request(id: "release", tokens: fixture.prompts.donor,
                scope: "tenant-a", answer: "ALDER-427", shouldHit: true)
            let branch = Request(id: "backup", tokens: fixture.prompts.branch,
                scope: "tenant-a", answer: "BRONZE-913", shouldHit: true)
            let pair = [first, branch]
            let allHit = pair + [
                Request(id: "release-copy", tokens: first.tokens, scope: first.scope, answer: first.answer, shouldHit: true),
                Request(id: "backup-copy", tokens: branch.tokens, scope: branch.scope, answer: branch.answer, shouldHit: true),
            ]
            let mixed = pair + [
                Request(id: "changed-prefix", tokens: fixture.prompts.changedPrefix,
                    scope: "tenant-a", answer: "CEDAR-682", shouldHit: false),
                Request(id: "other-tenant", tokens: branch.tokens,
                    scope: "tenant-b", answer: "BRONZE-913", shouldHit: false),
            ]

            let donorStore = try fixture.makeStore()
            let donorBridge = try fixture.makeBridge(store: donorStore)
            _ = try await GPTOSSMixedPrefixCohort.run(bridge: donorBridge, requests: [first],
                label: "seed", requiredDecodeWidth: 1, cacheOn: false)
            await donorStore.waitForWritesForTesting()
            let manifests = try fixture.persistedManifests()
            try #require(manifests.contains { $0.position >= 4_096 && branch.tokens.starts(with: $0.prefixTokens) })
            await donorBridge.shutdown()
            await donorStore.closeAndWait()

            // Exact same request arrays and cohort orders in both arms. Engines
            // never execute concurrently over the shared loaded model.
            let coldBridge = try fixture.makeBridge(store: nil, maxConcurrentRequests: 4)
            let coldPair = try await GPTOSSMixedPrefixCohort.run(bridge: coldBridge, requests: pair,
                label: "off-b2", requiredDecodeWidth: 2, cacheOn: false)
            // Full prefills stagger these short natural answers: four admitted
            // cold requests need not overlap at decode width four. This is a
            // concurrent semantic control, not cold full-width-four parity.
            // The restored B4 arm below must still execute native width four.
            let coldAll = try await GPTOSSMixedPrefixCohort.run(bridge: coldBridge, requests: allHit,
                label: "off-four-submitted", requiredDecodeWidth: 2, cacheOn: false)
            let coldMixed = try await GPTOSSMixedPrefixCohort.run(bridge: coldBridge, requests: mixed,
                label: "off-mixed4", requiredDecodeWidth: 2, cacheOn: false)
            await coldBridge.shutdown()

            let store = try fixture.makeStore()
            try #require(store.stats().entries > 0)
            let bridge = try fixture.makeBridge(store: store, maxConcurrentRequests: 4)
            let before = store.stats()
            let warmPair = try await GPTOSSMixedPrefixCohort.run(bridge: bridge, requests: pair,
                label: "on-b2", requiredDecodeWidth: 2, cacheOn: true)
            let warmReversed = try await GPTOSSMixedPrefixCohort.run(bridge: bridge, requests: Array(pair.reversed()),
                label: "on-b2-reversed", requiredDecodeWidth: 2, cacheOn: true)
            let warmAll = try await GPTOSSMixedPrefixCohort.run(bridge: bridge, requests: allHit,
                label: "on-b4", requiredDecodeWidth: 4, cacheOn: true)
            let warmMixed = try await GPTOSSMixedPrefixCohort.run(bridge: bridge, requests: mixed,
                label: "on-mixed4", requiredDecodeWidth: 2, cacheOn: true)
            await store.waitForWritesForTesting()
            let after = store.stats()
            let observedHits = [warmPair, warmReversed, warmAll, warmMixed]
                .flatMap { $0 }.filter { $0.hitTokens > 0 }.count
            #expect(after.stageConsumptions - before.stageConsumptions == observedHits,
                    "authenticated store consumptions must reconcile with actual row hits, including reversed order")
            #expect(after.stageReadBytes > before.stageReadBytes)
            #expect(after.stagedBytesInUse == 0 && after.writeHostBytesInUse == 0)
            for (cold, warm) in [(coldPair, warmPair), (coldAll, warmAll), (coldMixed, warmMixed)] {
                for (lhs, rhs) in zip(cold, warm) {
                    #expect(lhs.id == rhs.id && lhs.promptSHA256 == rhs.promptSHA256 && lhs.scope == rhs.scope)
                    print("[gptoss-mixed-comparison] id=\(lhs.id) sameText=\(lhs.text == rhs.text) "
                        + "offFirstObserved=\(lhs.firstObservedChunkSeconds) onFirstObserved=\(rhs.firstObservedChunkSeconds) "
                        + "offAnswer=\(lhs.answer.debugDescription) onAnswer=\(rhs.answer.debugDescription)")
                }
            }
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }
}
