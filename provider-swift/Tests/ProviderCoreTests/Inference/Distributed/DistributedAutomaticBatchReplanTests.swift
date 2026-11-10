import Foundation
import Testing
import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
@testable import ProviderCore

/// The local API's queued-demand replacement on a pair (pair-2, Gemma 4 26B
/// tensor parallel served locally, 2026-11-05): Gemma has no tensor-parallel
/// batch quote, so queued demand priced an 8-lane pipeline, which the local
/// server cannot swap in for a tensor-parallel generation (committed-token
/// logprobs are captured in tensor parallel only), so every attempt drained,
/// failed and reloaded the old setup, every ~35 s. Fabricated capabilities
/// only: no model, GPU or peer.
@Suite struct DistributedAutomaticBatchReplanTests {
    private func hash(_ c: Character) -> String { String(repeating: String(c), count: 64) }

    private func capability(adapter: ClusterRuntimeAdapter, model: String, profile: String) throws -> ClusterRuntimeCapability {
        try ClusterRuntimeCapability(runtimeBinarySHA256: hash("a"), adapterID: adapter.rawValue, adapterVersion: 1,
            runtimeModelID: model, artifactSHA256: hash("b"), configurationSHA256: hash("c"), manifestSHA256: hash("d"),
            profile: .init(id: profile, vocabularySize: 262_144, maximumPromptTokens: 32768, maximumOutputTokens: 32768,
                maximumChunkTokens: 512, maximumContextTokens: 65536),
            profileFingerprint: hash("e"), partitions: [.init(planSHA256: hash("f"), stages: [
                .init(rank: 0, sourceLayerStart: 0, sourceLayerEnd: 1, stagePlanSHA256: hash("1"), constructionConfigurationSHA256: hash("2")),
                .init(rank: 1, sourceLayerStart: 1, sourceLayerEnd: 2, stagePlanSHA256: hash("3"), constructionConfigurationSHA256: hash("4"))])],
            arithmeticPolicyID: adapter.arithmeticPolicyID, arithmeticPolicySHA256: hash("5"), supportedGenerationModes: [.pipeline, .tensorParallel])
    }

    private func gemma() throws -> ClusterRuntimeCapability {
        try capability(adapter: .gemma4LayerStage, model: "registered_gemma4_26b",
            profile: "registered_gemma4_26b_greedy_generation_v1")
    }

    /// The pipeline the planner priced for a tensor-parallel Gemma pair drops
    /// committed-token logprobs, so the local server refuses it after the drain;
    /// the planner refuses it before anything drains.
    @Test func aReplacementThatDropsAnEndpointFeatureIsNotProposed() throws {
        let cap = try gemma()
        #expect(!DistributedAutomaticBatchPlanner.keepsEndpointFeatures(capability: cap,
            running: .tensorParallel, proposed: .pipeline),
            "an 8-lane pipeline was proposed to replace a tensor-parallel Gemma generation")
        #expect(DistributedAutomaticBatchPlanner.keepsEndpointFeatures(capability: cap,
            running: .pipeline, proposed: .pipeline))
        #expect(DistributedAutomaticBatchPlanner.keepsEndpointFeatures(capability: cap,
            running: .tensorParallel, proposed: .tensorParallel))
    }

    /// The planner's predicate is the local server's: the session profile each
    /// mode would serve (`DistributedResidentExecutionProfile`) differs exactly
    /// when the planner refuses.
    @Test func thePlannersPredicateMatchesTheSessionBindingTheServerChecks() throws {
        let cap = try gemma()
        for (running, proposed) in [(ClusterGenerationMode.tensorParallel, ClusterGenerationMode.pipeline),
                                    (.pipeline, .pipeline), (.tensorParallel, .tensorParallel)] {
            let before = try DistributedResidentExecutionProfile(capability: cap, generationMode: running, requestTimeout: .seconds(315))
            let after = try DistributedResidentExecutionProfile(capability: cap, generationMode: proposed, requestTimeout: .seconds(315))
            #expect((before.supportsLogprobs == after.supportsLogprobs)
                == DistributedAutomaticBatchPlanner.keepsEndpointFeatures(capability: cap, running: running, proposed: proposed))
        }
    }

    /// A replacement that failed after release is not retried for that setup
    /// and width until a bounded backoff passes, which doubles on each repeat;
    /// a different setup is tried at once.
    @Test func aFailedReplacementBacksOffAndIsForgottenWhenTheSetupChanges() {
        let failures = DistributedAutomaticBatchFailures(), start = ContinuousClock.now
        #expect(failures.allows(setup: "s1", lanes: 8, now: start))
        failures.record(setup: "s1", lanes: 8, now: start)
        #expect(!failures.allows(setup: "s1", lanes: 8, now: start.advanced(by: .seconds(35))),
            "the same failing replacement was proposed again after ~35 s")
        #expect(failures.allows(setup: "s1", lanes: 4, now: start), "another width is not blocked")
        #expect(failures.allows(setup: "s2", lanes: 8, now: start), "a changed setup is tried at once")
        let first = DistributedAutomaticBatchFailures.initialHold
        #expect(failures.allows(setup: "s1", lanes: 8, now: start.advanced(by: first)))
        failures.record(setup: "s1", lanes: 8, now: start.advanced(by: first))
        #expect(!failures.allows(setup: "s1", lanes: 8, now: start.advanced(by: first * 2)), "the hold doubles")
        #expect(failures.allows(setup: "s1", lanes: 8, now: start.advanced(by: first * 3)))
        for _ in 0..<12 { failures.record(setup: "s1", lanes: 8, now: start) }
        #expect(failures.allows(setup: "s1", lanes: 8, now: start.advanced(by: DistributedAutomaticBatchFailures.maximumHold)),
            "the backoff is bounded")
    }

    /// The factory proposes no width a remembered failure holds back.
    @Test func theFactoryLeavesOutWidthsThatFailed() {
        let demand = DistributedLocalBatchDemand(generationID: UUID(), waitingRequests: 7, activeRequests: 1,
            currentCapacity: 1, publicModelID: "fixture-model", runtimeModelID: "registered_gemma4_26b",
            artifactSHA256: hash("b"), configurationSHA256: hash("c"), maximumPromptTokens: 32768,
            maximumOutputTokens: 32768, maximumContextTokens: 65536, requestTimeout: .seconds(315))
        let all = DistributedAutomaticBatchFactory.replacementWidths(for: demand)
        #expect(all.first == 8)
        let failures = DistributedAutomaticBatchFailures()
        failures.record(setup: "s1", lanes: 8)
        let held = DistributedAutomaticBatchFactory.replacementWidths(for: demand, setup: "s1", failures: failures)
        #expect(!held.contains(8))
        #expect(held == all.filter { $0 != 8 })
    }

    /// Gemma's tensor-parallel batch width is not priced (it has no tensor-parallel batch quote), so a Gemma TP setup
    /// serves one request at a time, and the mode question says so: never "up to 8".
    @Test func anUnpricedTensorParallelWidthServesAndSaysOneRequestAtATime() {
        #expect(!ClusterPlacementTensorBatchQuote.runtimeModelIDs.contains("registered_gemma4_26b"))
        #expect(DistributedInstalledPlan.defaultBatchLanes(adapter: .gemma4LayerStage, mode: .tensorParallel,
            hasPrivateImages: false, runtimeModelID: "registered_gemma4_26b") == 1)
        let advice = ClusterOnboardingModeAdvice.advise([
            .init(mode: ClusterGenerationMode.tensorParallel.rawValue, planned: true, fitsNow: true,
                  predictedTokensPerSecond: 50, concurrentRequests: 1),
            .init(mode: ClusterGenerationMode.pipeline.rawValue, planned: true, fitsNow: true,
                  predictedTokensPerSecond: 30, concurrentRequests: 4),
        ], throughDarkbloom: false, serving: false)
        #expect(advice?.reason.contains("up to 8") == false)
        let mode = ClusterOnboardingMode(mode: ClusterGenerationMode.tensorParallel.rawValue, split: nil,
            measuredTokensPerSecond: nil, concurrentRequests: 1)
        #expect(mode.requestsWords == "serves one request at a time")
    }

    /// At one lane a cancel during the prompt is a clean stop at the first token, so the lane is held until the prompt
    /// is read (the documented limitation, as R4-14 on a GLM pipeline); only a pair whose lanes retire alone (2-8
    /// lanes) ends it at the next step.
    @Test func aSingleLaneTensorParallelPairKeepsTheCleanStop() {
        #expect(!DistributedInstalledPlan.lanesRetireAlone(adapter: .gemma4LayerStage, mode: .tensorParallel,
            hasPrivateImages: false, lanes: 1, runtimeModelID: "registered_gemma4_26b"))
        #expect(DistributedInstalledPlan.lanesRetireAlone(adapter: .gemma4LayerStage, mode: .tensorParallel,
            hasPrivateImages: false, lanes: 4, runtimeModelID: "registered_gemma4_26b"))
    }
}
