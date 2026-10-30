import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

/// A cluster pair applies the single-Mac slot's client stop-string scope: on
/// GPT-OSS only the Harmony final message can end a request, so reasoning text
/// cannot end it with an empty answer. Fabricated owner only: no model, GPU or
/// peer process.
@Suite(.timeLimit(.minutes(1)))
struct DistributedStopStringScopeTests {
    @Test func clusterBridgeTakesTheSingleMacScopeForItsModel() async throws {
        let owner = DistributedTestOwner()
        let scope = try #require(ModelEOSPolicy.stopStringScope(modelId: owner.identity.modelID, modelType: "gpt_oss"))
        let gptOSS = try DistributedEngineFactory.makeBridge(owner: owner, expectedIdentity: owner.identity,
            profile: distributedTestProfile(), tokenizer: TokenizerHandle(DistributedTestTokenizer()), eosTokenIDs: [99],
            modelType: "gpt_oss")
        #expect(gptOSS.stopStringScope == scope)
        await gptOSS.shutdown()
        let plain = DistributedTestOwner()
        let other = try DistributedEngineFactory.makeBridge(owner: plain, expectedIdentity: plain.identity,
            profile: distributedTestProfile(), tokenizer: TokenizerHandle(DistributedTestTokenizer()), eosTokenIDs: [99],
            modelType: nil)
        #expect(other.stopStringScope == nil)
        await other.shutdown()
    }

    @Test func admissionMakesTheDetokenizerWithTheRequestScope() async throws {
        let owner = DistributedTestOwner(), detokenizers = DistributedTestDetokenizers()
        let engine = try DistributedCBv2Engine(owner: owner, expectedIdentity: owner.identity,
            profile: distributedTestProfile(), detokenizers: detokenizers)
        let scope = try #require(ModelEOSPolicy.stopStringScope(modelId: "gpt-oss-20b"))
        var scoped = distributedTestRequest(1, maxTokens: 1)
        scoped.stopStringScope = scope
        let cases: [(CBv2Request, [CBv2StopStringScope?])] = [
            (scoped, [scope]), (distributedTestRequest(2, maxTokens: 1), [scope, nil]),
        ]
        for (request, expected) in cases {
            let stream = try engine.submit(request)
            #expect(detokenizers.scopes == expected)
            owner.last.send(.token(4))
            owner.last.send(.finished(.length))
            owner.last.acknowledge()
            _ = await distributedCollect(stream)
        }
        await engine.shutdown()
    }
}
