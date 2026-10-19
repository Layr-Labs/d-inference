import CryptoKit
import DarkbloomClusterProtocol
import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

/// Runs the actual cluster image ingress, bridge, scheduler and streaming
/// parser. Only peer generation is scripted; no model or GPU is involved.
@Suite("GLM cluster image reasoning stream", .serialized, .timeLimit(.minutes(1)))
struct GLMClusterImageReasoningTests {
    @Test(arguments: ["<think>", "</think>"])
    func promptReasoningStateSurvivesLengthTermination(tail: String) async throws {
        var config = try #require(JSONSerialization.jsonObject(with:
            JSONEncoder().encode(GLM5NextInventoryFixture.configuration())) as? [String: Any])
        config["image_token_id"] = 154854
        config["video_token_id"] = 154855
        config["image_start_token_id"] = 154830
        config["image_end_token_id"] = 154831
        config["video_start_token_id"] = 154832
        config["video_end_token_id"] = 154833
        var text = try #require(config["text_config"] as? [String: Any])
        text["vocab_size"] = 160000
        text["max_position_embeddings"] = 4096
        config["text_config"] = text
        let bytes = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        let owner = GLMImageReasoningOwner(configuration: bytes)
        let profile = try DistributedResidentExecutionProfile(id: ClusterGLMImageCandidate.profileID,
            vocabularySize: 160000, maxPromptTokens: 2048, maxOutputTokens: 128,
            maxContextTokens: 4096, requestTimeout: .seconds(30))
        let tokenizer = TokenizerHandle(GLMImageReasoningTokenizer(tail: tail))
        let distributed = try DistributedCBv2Engine(owner: owner, expectedIdentity: owner.identity,
            profile: profile, detokenizers: DistributedTestDetokenizers())
        let bridge = EngineV2Bridge(engine: distributed, modelId: "fixture/glm-image-reasoning",
            tokenizer: tokenizer, eosTokenIds: [], defaultMaxTokens: 128,
            defaultMaxTokensContextLimit: 4096, clusterGLMImageConfiguration: bytes)
        let entry = MultiModelBatchSchedulerEngine.ModelRegistryEntry(
            tokenizer: tokenizer, modelType: "glm5_next", engineV2Bridge: bridge)
        let scheduler = MultiModelBatchSchedulerEngine(registryProvider: {
            ["fixture/glm-image-reasoning": entry]
        })
        let png = "data:image/png;base64,"
            + "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAAAXNSR0IArs4c6QAAAERl"
            + "WElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAAB"
            + "AAAAAaADAAQAAAABAAAAAQAAAAD5Ip3+AAAADElEQVQIHWP4z8AAAAMBAQBb2/lEAAAA"
            + "AElFTkSuQmCC"
        var request = OpenAIChatCompletionRequest(model: "fixture/glm-image-reasoning",
            messages: [.init(role: .user, content: .parts([.text("Describe."), .imageURL(png)]))],
            stream: true, temperature: 0, maxTokens: 1)
        request.reasoningParser = .qwen3
        let stream = try await scheduler.streamChatCompletion(request: request)
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while owner.lastLease?.startCount != 1, ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(5))
        }
        let lease = try #require(owner.lastLease)
        #expect(lease.startCount == 1)
        #expect(owner.lastRequest?.clusterStillImages != nil)
        _ = lease.send(.token(42))
        _ = lease.send(.finished(.length))
        lease.acknowledge()
        var parser = StreamingReasoningParser(format: .qwen3)
        var parsed: [ParsedReasoning] = []
        var finish: String?
        for try await event in stream {
            switch event {
            case .content(let chunk): parsed += parser.parse(chunk)
            case .parsed(let value): parsed.append(value)
            case .info(let info): finish = info.stopReason
            case .toolCall: Issue.record("Unexpected tool call")
            }
        }
        parsed += parser.finish()
        #expect(finish == "length")
        let answer = parsed.map(\.content).joined()
        let reasoning = parsed.compactMap(\.reasoningContent).joined()
        #expect(answer == (tail == "<think>" ? "" : "t42"))
        #expect(reasoning == (tail == "<think>" ? "t42" : ""))
        await distributed.shutdown()
    }
}

private struct GLMImageReasoningTokenizer: MLXLMCommon.Tokenizer {
    let tail: String
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [1] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { tail }
    func convertTokenToId(_ token: String) -> Int? {
        ["<|image|>": 154854, "<|video|>": 154855,
         "<|begin_of_image|>": 154830, "<|end_of_image|>": 154831,
         "<|begin_of_video|>": 154832, "<|end_of_video|>": 154833][token]
    }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        [1, 154830, 154854, 154831, 2]
    }
}

private final class GLMImageReasoningOwner: DistributedResidentExecutionOwner, @unchecked Sendable {
    let identity: DistributedResidentIdentity
    private let lock = NSLock()
    private var lease: DistributedTestLease?
    private var request: CBv2Request?
    var lastLease: DistributedTestLease? { lock.withLock { lease } }
    var lastRequest: CBv2Request? { lock.withLock { request } }
    init(configuration: Data) {
        identity = .init(membershipEpoch: UUID(), modelID: "registered_glm53_flash",
            artifactSHA256: String(repeating: "a", count: 64),
            configurationSHA256: SHA256.hash(data: configuration).map { String(format: "%02x", $0) }.joined(),
            peers: [.init(id: "fixture-0", buildSHA256: String(repeating: "b", count: 64)),
                    .init(id: "fixture-1", buildSHA256: String(repeating: "b", count: 64))])
    }
    func readiness() -> DistributedResidentReadiness? {
        .init(identity: identity, profileID: ClusterGLMImageCandidate.profileID, requestCapacityBytes: 1 << 20)
    }
    func setReadinessInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {}
    func projectFirstToken(_ request: CBv2Request, admission: CBv2FirstTokenDeadlineAdmission) -> CBv2FirstTokenProjectedWork {
        .unbounded(reason: nil)
    }
    func reserve(_ request: CBv2Request, identity: DistributedResidentIdentity,
                 profileID: String, capacityLimit: Int) throws -> any DistributedResidentRequestLease {
        guard identity == self.identity, profileID == ClusterGLMImageCandidate.profileID else {
            throw DistributedEngineError.unavailable
        }
        let value = DistributedTestLease(identity: identity, requestID: request.id)
        lock.withLock { self.request = request; lease = value }
        return value
    }
    func shutdown() async {}
}
