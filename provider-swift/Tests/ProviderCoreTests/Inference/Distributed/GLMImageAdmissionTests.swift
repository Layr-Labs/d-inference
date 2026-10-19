import Foundation
import DarkbloomClusterProtocol
import MLXLMCommon
import Testing
@testable import ProviderCore

@Suite("GLM explicit media admission", .serialized)
struct GLMImageAdmissionTests {
    @Test func ordinaryTextGrantRefusesDirectImageBeforeOwnerReserve() async throws {
        let owner = DistributedTestOwner()
        owner.profileID = ClusterGLMImageCandidate.textProfileID
        let profile = try DistributedResidentExecutionProfile(id: owner.profileID, vocabularySize: 100,
            maxPromptTokens: 16, maxOutputTokens: 4, maxContextTokens: 20, requestTimeout: .seconds(10))
        let engine = try DistributedCBv2Engine(owner: owner, expectedIdentity: owner.identity,
            profile: profile, detokenizers: DistributedTestDetokenizers())
        let png = Data([137,80,78,71,13,10,26,10] + Array(repeating: UInt8(0), count: 32))
        let media = ClusterStillImages(configurationSHA256: owner.identity.configurationSHA256,
            images: [.init(png: png, width: 1, height: 1, tokenOffset: 1, tokenCount: 1)])
        var request = distributedTestRequest(maxTokens: 1)
        request.clusterStillImages = try JSONEncoder().encode(media)
        #expect(throws: DistributedEngineError.refused(.mediaUnsupported)) { _ = try engine.submit(request) }
        #expect(owner.reserveCount == 0)
        request.clusterStillImages = nil
        let stream = try engine.submit(request)
        #expect(owner.reserveCount == 1)
        _ = owner.last.send(.token(4)); owner.last.acknowledge()
        _ = await distributedCollect(stream)
        await engine.shutdown()
    }

    @Test func factoryCannotEnableImagesForAnOrdinaryGLMProfileOrForeignSource() async throws {
        let owner = DistributedTestOwner()
        owner.profileID = ClusterGLMImageCandidate.textProfileID
        let profile = try DistributedResidentExecutionProfile(id: owner.profileID, vocabularySize: 100,
            maxPromptTokens: 16, maxOutputTokens: 4, maxContextTokens: 20, requestTimeout: .seconds(10))
        // No model directory is needed for text; a build containing image code
        // must not attempt to construct image ingress or require its metadata.
        let bridge = try DistributedEngineFactory.makeBridge(owner: owner, expectedIdentity: owner.identity,
            profile: profile, tokenizer: TokenizerHandle(DistributedAdmissionTokenizer()), eosTokenIDs: [], modelType: "glm5_next")
        let imageConfiguration = await bridge.clusterGLMImageConfiguration
        #expect(imageConfiguration == nil)
        #expect(throws: (any Error).self) {
            try ClusterGLMImageCandidate.validateSource(profileID: ClusterGLMImageCandidate.profileID,
                modelID: owner.identity.modelID, artifact: owner.identity.artifactSHA256,
                configuration: owner.identity.configurationSHA256)
        }
    }
}

private struct DistributedAdmissionTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [1] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "fixture" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }; var eosToken: String? { nil }; var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] { [1] }
}
