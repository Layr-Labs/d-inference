import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

@Suite struct DistributedStopResolutionTests {
    @Test func legacyFactoryStillUnionsModelAndTokenizerStops() async throws {
        let owner = DistributedTestOwner()
        let bridge = try DistributedEngineFactory.makeBridge(owner: owner,
            expectedIdentity: owner.identity, profile: distributedTestProfile(),
            tokenizer: TokenizerHandle(DistributedTestTokenizer()), eosTokenIDs: [98])
        let stops = await bridge.stopTokenIds
        #expect(stops == [98, 99])
        await bridge.shutdown()
    }

    @Test func alreadyResolvedEmptyStopsSurviveRegistryAndBridgeConstruction() async throws {
        let owner = DistributedTestOwner()
        let entry = try DistributedEngineFactory.makeRegistryEntry(owner: owner,
            expectedIdentity: owner.identity, publicModelID: "public/example",
            profile: distributedTestProfile(), tokenizer: TokenizerHandle(DistributedTestTokenizer()),
            eosTokenIDs: [98], resolvedStopTokenIDs: [])
        let bridge = try #require(entry.engineV2Bridge)
        let stops = await bridge.stopTokenIds
        #expect(stops.isEmpty)
        await bridge.shutdown()
    }

    @Test func resolvedStopsStillRequireTheActualProfileVocabulary() throws {
        for invalid in [-1, 100] {
            let owner = DistributedTestOwner()
            #expect(throws: DistributedEngineError.self) {
                try DistributedEngineFactory.makeBridge(owner: owner,
                    expectedIdentity: owner.identity, profile: distributedTestProfile(),
                    tokenizer: TokenizerHandle(DistributedTestTokenizer()), eosTokenIDs: [],
                    resolvedStopTokenIDs: [invalid])
            }
            #expect(owner.reserveCount == 0)
        }
    }
}
