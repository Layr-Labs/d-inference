import CryptoKit
import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXLMCommon
import MLXLMServer
import MLXVLM
import Testing
@testable import ProviderCore

/// GLM images on the tensor-parallel pair, the leader's half, through the
/// actual scheduler, bridge and distributed engine: the request leaves with
/// the product's expanded prompt and an envelope whose bytes, spans and patch
/// digest are the product's. Peer generation is scripted; no model is loaded
/// (the processor's patches are host values on the CPU device).
@Suite("GLM cluster tensor-parallel media ingress", .serialized, .timeLimit(.minutes(1)))
struct GLMClusterTensorParallelMediaTests {
    static let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAAAXNSR0IArs4c6QAAAERl"
        + "WElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAAB"
        + "AAAAAaADAAQAAAABAAAAAQAAAAD5Ip3+AAAADElEQVQIHWP4z8AAAAMBAQBb2/lEAAAA"
        + "AElFTkSuQmCC"

    static func configuration() throws -> Data {
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
        text["dtype"] = "bfloat16"
        config["text_config"] = text
        return try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
    }

    /// The artifact's processor contract at the fixture's patch geometry.
    static func processorConfiguration() throws -> Data {
        func media(_ type: String, _ key: String, maximum: Int, fps: Bool) -> [String: Any] {
            var value: [String: Any] = ["do_rescale": true, "patch_expand_factor": 1, "merge_size": 2,
                "image_mean": GLM5NextProcessor.mean.map(Double.init), "image_std": GLM5NextProcessor.standardDeviation.map(Double.init),
                "temporal_patch_size": 2, "patch_size": 2, "min_image_tokens": 16, "max_image_tokens": maximum, key: type]
            if fps { value["fps"] = 2 }
            return value
        }
        return try JSONSerialization.data(withJSONObject: [
            "processor_class": "Glm5NextProcessor",
            "image_processor": media("Glm5NextImageProcessor", "image_processor_type", maximum: 8000, fps: false),
            "video_processor": media("Glm5NextVideoProcessor", "video_processor_type", maximum: 240000, fps: true),
        ])
    }

    @Test func imageRequestLeavesWithTheProductsPromptAndAnEnvelope() async throws {
        let bytes = try Self.configuration()
        let ingress = try DistributedGLMMediaIngress(configuration: bytes,
            processorConfiguration: Self.processorConfiguration(),
            expectedSHA256: ClusterGLMMedia.sha256(bytes))
        let owner = GLMTensorParallelMediaOwner(configuration: bytes)
        let profile = try DistributedResidentExecutionProfile(id: ClusterGLMImageCandidate.textProfileID,
            vocabularySize: 160000, maxPromptTokens: 2048, maxOutputTokens: 128,
            maxContextTokens: 4096, requestTimeout: .seconds(30))
        let tokenizer = TokenizerHandle(GLMTensorParallelMediaTokenizer())
        let distributed = try DistributedCBv2Engine(owner: owner, expectedIdentity: owner.identity,
            profile: profile, detokenizers: DistributedTestDetokenizers())
        let bridge = EngineV2Bridge(engine: distributed, modelId: "fixture/glm-tp-media",
            tokenizer: tokenizer, eosTokenIds: [], defaultMaxTokens: 128,
            defaultMaxTokensContextLimit: 4096, clusterGLMMediaIngress: ingress)
        let entry = MultiModelBatchSchedulerEngine.ModelRegistryEntry(
            tokenizer: tokenizer, modelType: "glm5_next", engineV2Bridge: bridge)
        let scheduler = MultiModelBatchSchedulerEngine(registryProvider: { ["fixture/glm-tp-media": entry] })
        let request = OpenAIChatCompletionRequest(model: "fixture/glm-tp-media",
            messages: [.init(role: .user, content: .parts([.text("Describe."), .imageURL("data:image/png;base64," + Self.png)]))],
            stream: true, temperature: 0, maxTokens: 1)
        let stream = try await scheduler.streamChatCompletion(request: request)
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while owner.lastLease?.startCount != 1, ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(5))
        }
        let lease = try #require(owner.lastLease)
        let sent = try #require(owner.lastRequest)
        let media = try ClusterGLMMedia.decodeBounded(try #require(sent.clusterGLMMedia))
        #expect(sent.clusterStillImages == nil && sent.multimodal == nil)
        // The rendered prompt [1, begin, image x n, end, 2], the image's span after its begin marker.
        let item = try #require(media.items.first)
        let n = item.tokensPerFrame
        #expect(media.items.count == 1 && item.kind == .image && item.temporal == 1)
        #expect(sent.promptTokens == [1, 154830] + Array(repeating: 154854, count: n) + [154831, 2])
        #expect(item.tokenOffsets == [2] && item.encoded == Data(base64Encoded: Self.png))
        try media.verifyEncodedBytes()
        #expect(media.configurationSHA256 == ClusterGLMMedia.sha256(bytes))
        // Rank 0's path: the SDK's media half on the product's ingest decode
        // reproduces the leader's patch digest.
        let decoded = try MediaIngest.decodeImageData(try #require(Data(base64Encoded: Self.png)))
        let values = try await GLM5NextProcessor(imageConfiguration: ingress.processor)
            .prepareMediaValues(images: [decoded], videos: []).images[0].values
        let digest = values.withUnsafeBytes { SHA256.hash(data: $0) }.map { String(format: "%02x", $0) }.joined()
        #expect(digest == item.patchesSHA256)
        _ = lease.send(.token(42))
        _ = lease.send(.finished(.length))
        lease.acknowledge()
        for try await _ in stream {}
        await distributed.shutdown()
    }

    @Test func videoAndRefusalsFollowTheProduct() async throws {
        let bytes = try Self.configuration()
        let ingress = try DistributedGLMMediaIngress(configuration: bytes,
            processorConfiguration: Self.processorConfiguration(),
            expectedSHA256: ClusterGLMMedia.sha256(bytes))
        // A malformed video is the ingest's own 4xx error, before any envelope.
        let bad = OpenAIChatCompletionRequest(model: "m", messages: [.init(role: .user,
            content: .parts([.videoURL("data:video/mp4;base64,AAAA")]))])
        await #expect(throws: MediaIngest.MediaError.self) {
            _ = try await ingress.prepare(request: bad, controls: .init(), tokenizer: GLMTensorParallelMediaTokenizer())
        }
        // Media off the user role is refused as the product refuses it.
        let system = OpenAIChatCompletionRequest(model: "m", messages: [.init(role: .system,
            content: .parts([.imageURL("data:image/png;base64," + Self.png)]))])
        await #expect(throws: (any Error).self) {
            _ = try await ingress.prepare(request: system, controls: .init(), tokenizer: GLMTensorParallelMediaTokenizer())
        }
        // A configuration other than the loaded peers' is refused at binding.
        #expect(throws: (any Error).self) {
            _ = try DistributedGLMMediaIngress(configuration: bytes,
                processorConfiguration: Self.processorConfiguration(), expectedSHA256: String(repeating: "0", count: 64))
        }
    }
}

private struct GLMTensorParallelMediaTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [1] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "t" }
    func convertTokenToId(_ token: String) -> Int? {
        ["<|image|>": 154854, "<|video|>": 154855,
         "<|begin_of_image|>": 154830, "<|end_of_image|>": 154831,
         "<|begin_of_video|>": 154832, "<|end_of_video|>": 154833,
         "<think>": 151000, "</think>": 151001][token]
    }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        var tokens = [1]
        for message in messages {
            guard let content = message["content"] as? [[String: String]] else { continue }
            for part in content where part["type"] == "image" { tokens += [154830, 154854, 154831] }
            for part in content where part["type"] == "video" { tokens += [154832, 154855, 154833] }
        }
        return tokens + [2]
    }
}

private final class GLMTensorParallelMediaOwner: DistributedResidentExecutionOwner, @unchecked Sendable {
    let identity: DistributedResidentIdentity
    private let lock = NSLock()
    private var lease: DistributedTestLease?
    private var request: CBv2Request?
    var lastLease: DistributedTestLease? { lock.withLock { lease } }
    var lastRequest: CBv2Request? { lock.withLock { request } }
    init(configuration: Data) {
        identity = .init(membershipEpoch: UUID(), modelID: ClusterGLMImageCandidate.runtimeModelID,
            artifactSHA256: String(repeating: "a", count: 64), configurationSHA256: ClusterGLMMedia.sha256(configuration),
            peers: [.init(id: "fixture-0", buildSHA256: String(repeating: "b", count: 64)),
                    .init(id: "fixture-1", buildSHA256: String(repeating: "b", count: 64))])
    }
    func readiness() -> DistributedResidentReadiness? {
        .init(identity: identity, profileID: ClusterGLMImageCandidate.textProfileID, requestCapacityBytes: 1 << 20,
            media: ClusterGLMMedia.contract)
    }
    func setReadinessInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {}
    func projectFirstToken(_ request: CBv2Request, admission: CBv2FirstTokenDeadlineAdmission) -> CBv2FirstTokenProjectedWork {
        .unbounded(reason: nil)
    }
    func reserve(_ request: CBv2Request, identity: DistributedResidentIdentity,
                 profileID: String, capacityLimit: Int) throws -> any DistributedResidentRequestLease {
        guard identity == self.identity, profileID == ClusterGLMImageCandidate.textProfileID else {
            throw DistributedEngineError.unavailable
        }
        let value = DistributedTestLease(identity: identity, requestID: request.id)
        lock.withLock { self.request = request; lease = value }
        return value
    }
    func shutdown() async {}
}
