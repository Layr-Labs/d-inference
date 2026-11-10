// Copyright © 2026 Eigen Labs.
// The opt-in canonical prefill grid: the values the provider accepts, and the
// ones that keep today's chunking.

import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("Canonical prefill grid configuration")
struct EngineV2CanonicalGridTests {
    private static let grid = EngineV2Factory.canonicalPrefillGridKey
    private static let boundaries = EngineV2Factory.canonicalBoundariesKey

    private func scheduler(_ environment: [String: String]) -> CBv2SchedulerConfig {
        EngineV2Factory.productionSchedulerConfig(maxConcurrentRequests: 8, environment: environment)
    }

    @Test("unset keeps today's chunking, and a rule alone does nothing")
    func offByDefault() {
        let plain = scheduler([:])
        #expect(plain.canonicalPrefillGridTokens == nil)
        #expect(plain.canonicalBoundaryRule == nil)
        #expect(scheduler([Self.boundaries: "1,2;3"]).canonicalBoundaryRule == nil)
    }

    @Test("a grid is a whole number of query blocks, at most the plain chunk")
    func gridFitsThePlainChunk() {
        #expect(scheduler([:]).prefillChunkSize == 512)
        #expect(scheduler([Self.grid: "512"]).canonicalPrefillGridTokens == 512)
        #expect(scheduler([Self.grid: " 256 "]).canonicalPrefillGridTokens == 256)
        for refused in ["0", "-128", "100", "640", "1024", "512k", ""] {
            #expect(scheduler([Self.grid: refused]).canonicalPrefillGridTokens == nil, "\(refused)")
        }
    }

    @Test("a grid leaves half the step budget for other rows")
    func gridFitsHalfTheStepBudget() {
        let wideChunk = [EngineV2Factory.prefillChunkKey: "2048", Self.grid: "2048"]
        #expect(scheduler(wideChunk).maxBatchedTokensPerStep == 4096)
        #expect(scheduler(wideChunk).canonicalPrefillGridTokens == 2048)

        let tightStep = wideChunk.merging([EngineV2Factory.stepTokenBudgetKey: "2048"]) { $1 }
        #expect(scheduler(tightStep).maxBatchedTokensPerStep == 2048)
        #expect(scheduler(tightStep).canonicalPrefillGridTokens == nil)
        #expect(
            scheduler(tightStep.merging([Self.grid: "1024"]) { $1 }).canonicalPrefillGridTokens
                == 1024)
    }

    @Test("a grid cell fits the prompt share of a step that also decodes")
    func gridFitsTheMixedStepCap() {
        let capped = [MixedPrefillPolicy.globalKey: "256"]
        #expect(scheduler(capped).mixedStepPrefillTokenCap == 256)
        #expect(
            scheduler(capped.merging([Self.grid: "512"]) { $1 }).canonicalPrefillGridTokens == nil)
        #expect(
            scheduler(capped.merging([Self.grid: "256"]) { $1 }).canonicalPrefillGridTokens == 256)
        // Zero already stops every prompt row while a row decodes.
        let stopped = [MixedPrefillPolicy.globalKey: "0", Self.grid: "512"]
        #expect(scheduler(stopped).canonicalPrefillGridTokens == 512)
    }

    @Test("an operator rule is read whole or not at all")
    func operatorRule() {
        func rule(_ raw: String) -> CBv2CanonicalBoundaryRule? {
            scheduler([Self.grid: "512", Self.boundaries: raw]).canonicalBoundaryRule
        }
        #expect(rule("7,8,9;10,11") == CBv2CanonicalBoundaryRule(open: [7, 8, 9], close: [[10, 11]]))
        #expect(
            rule(" 7, 8 ;10,11|12") == CBv2CanonicalBoundaryRule(open: [7, 8], close: [[10, 11], [12]]))
        for malformed in ["", "7,8", "7,8;", ";10", "7,,8;10", "7,x;10", "7;10|", "7;10;11", "-7;10"] {
            #expect(rule(malformed) == nil, "\(malformed)")
        }
    }

    @Test("routes with their own chunking clear the grid")
    func routesWithTheirOwnChunkingAreExcluded() {
        let base = scheduler([Self.grid: "512", Self.boundaries: "7;10"])
        #expect(base.canonicalPrefillGridTokens == 512 && base.canonicalBoundaryRule != nil)
        let protected = EngineV2Factory.glm5NextServingScheduler(base, context: 32_768)
        #expect(protected.canonicalPrefillGridTokens == nil)
        #expect(protected.canonicalBoundaryRule == nil)

        var superLocal = base
        NemotronSuperLocalPrefill.Policy(chunkTokens: 256, decodeStepsBetweenChunks: 4)
            .apply(to: &superLocal, requests: 4, draftTokens: 0)
        #expect(superLocal.prefillChunkSize == 256)
        #expect(superLocal.canonicalPrefillGridTokens == nil)
        #expect(superLocal.canonicalBoundaryRule == nil)
    }
}
