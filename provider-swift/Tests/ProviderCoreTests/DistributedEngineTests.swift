import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import ProviderCore

/// End-to-end on one machine: the bring-up handshake over the in-memory channel,
/// MLX ring hostfile shape, and a full 2-rank `DistributedInferenceEngine`
/// decode over the loopback runtime. The only stubbed pieces are the model-bound
/// shard internals (a deterministic mock) and the real MLX ring (loopback).
@Suite("DistributedEngine")
struct DistributedEngineTests {

    private struct SoftSigner: AttestationSigner {
        let pk = P256.Signing.PrivateKey()
        func sign(_ d: Data) throws -> Data { try pk.signature(for: d).derRepresentation }
        var publicKeyBase64: String { pk.publicKey.rawRepresentation.base64EncodedString() }
    }

    private func roster(_ a: SoftSigner, _ b: SoftSigner) -> ClusterRosterBody {
        ClusterRosterBody(
            clusterId: "c1",
            members: [
                ClusterMember(nodeId: "node-a", sePublicKeyBase64: a.publicKeyBase64,
                              x25519PublicKeyBase64: NodeKeyPair.generate().publicKeyBase64, trustLevel: "hardware"),
                ClusterMember(nodeId: "node-b", sePublicKeyBase64: b.publicKeyBase64,
                              x25519PublicKeyBase64: NodeKeyPair.generate().publicKeyBase64, trustLevel: "hardware"),
            ],
            issuedAt: Date(timeIntervalSince1970: 0),
            expiresAt: Date(timeIntervalSince1970: 1e12))
    }

    @Test func bringupHandshakeOverInMemoryChannel() async throws {
        let a = SoftSigner(); let b = SoftSigner()
        let r = roster(a, b)
        let pair = InMemoryHandshakeChannelPair()
        async let sa = ClusterHandshakeRunner.runInitiator(
            clusterId: "c1", localNodeId: "node-a", signer: a, roster: r, channel: pair.a)
        async let sb = ClusterHandshakeRunner.runResponder(
            localNodeId: "node-b", signer: b, roster: r, channel: pair.b)
        let sessionA = try await sa
        let sessionB = try await sb
        #expect(sessionA.sendKey() == sessionB.recvKey())
        #expect(sessionB.sendKey() == sessionA.recvKey())
    }

    @Test func mlxRingHostfileShape() throws {
        let plan = try ClusterPlan.resolve(ClusterSettings(
            enabled: true, clusterId: "c1", nodeId: "node-a",
            members: [
                ClusterMemberSettings(nodeId: "node-a", address: "10.0.0.1"),
                ClusterMemberSettings(nodeId: "node-b", address: "10.0.0.2:6000"),
            ]))
        let json = try MLXRingEnvironment.hostfileJSON(plan)
        let parsed = try JSONSerialization.jsonObject(with: json) as! [[String]]
        #expect(parsed.count == 2)
        #expect(parsed[0] == ["10.0.0.1:5680"])
        #expect(parsed[1] == ["10.0.0.2:6000"])
    }

    // Deterministic mock shard: hidden state is [1, vocab]; embed seeds it by the
    // running length so argmax advances each step; layers are identity; tail
    // projects the (already vocab-shaped) hidden state to logits.
    private struct MockShard: PipelineModelShard {
        let totalLayers: Int
        let ownedInterval: LayerInterval
        let vocab: Int
        func embed(tokens: [Int]) -> MLXArray {
            MLXArray(converting: (0..<vocab).map { i in
                i == (tokens.count % vocab) ? 10.0 : 0.0   // argmax = running length mod vocab
            }, [1, vocab])
        }
        func runOwnedLayers(_ hidden: MLXArray) -> MLXArray { hidden }
        func projectToLogits(_ hidden: MLXArray) -> MLXArray { hidden }
    }

    private struct StubTokenizer: Tokenizer {
        func encode(text: String, addSpecialTokens: Bool) -> [Int] { Array(text.utf8).map(Int.init) }
        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "t\(tokenIds.first ?? -1) " }
        func convertTokenToId(_ token: String) -> Int? { nil }
        func convertIdToToken(_ id: Int) -> String? { nil }
        var bosToken: String? { nil }
        var eosToken: String? { nil }
        var unknownToken: String? { nil }
        func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] { [1, 2, 3] }
        func applyChatTemplate(messages: [[String: any Sendable]], chatTemplate: String) throws -> [Int] { [1, 2, 3] }
        func applyChatTemplate(messages: [[String: any Sendable]], chatTemplate: String, tools: [[String: any Sendable]]?, additionalContext: [String: any Sendable]?) throws -> [Int] { [1, 2, 3] }
    }

    @Test func twoRankEngineStreamsTokens() async throws {
        let a = SoftSigner(); let b = SoftSigner()
        let r = roster(a, b)

        // Sessions via the handshake.
        let pair = InMemoryHandshakeChannelPair()
        async let sa = ClusterHandshakeRunner.runInitiator(
            clusterId: "c1", localNodeId: "node-a", signer: a, roster: r, channel: pair.a)
        async let sb = ClusterHandshakeRunner.runResponder(
            localNodeId: "node-b", signer: b, roster: r, channel: pair.b)
        let sessionA = try await sa
        let sessionB = try await sb

        let planA = try ClusterPlan.resolve(ClusterSettings(
            enabled: true, clusterId: "c1", nodeId: "node-a",
            members: [ClusterMemberSettings(nodeId: "node-a", address: "10.0.0.1"),
                      ClusterMemberSettings(nodeId: "node-b", address: "10.0.0.2")]))
        let planB = try ClusterPlan.resolve(ClusterSettings(
            enabled: true, clusterId: "c1", nodeId: "node-b",
            members: [ClusterMemberSettings(nodeId: "node-a", address: "10.0.0.1"),
                      ClusterMemberSettings(nodeId: "node-b", address: "10.0.0.2")]))

        // Shared loopback fabric for both ranks.
        let mailbox = LoopbackMailbox()
        let tokenBus = LoopbackTokenBus()
        let vocab = 8
        let runtimeA = LoopbackClusterRuntime(
            plan: planA, mailbox: mailbox, tokenBus: tokenBus,
            sendSession: sessionA, recvSession: nil)
        let runtimeB = LoopbackClusterRuntime(
            plan: planB, mailbox: mailbox, tokenBus: tokenBus,
            sendSession: nil, recvSession: sessionB)

        let engineA = DistributedInferenceEngine(plan: planA, runtime: runtimeA)
        let engineB = DistributedInferenceEngine(plan: planB, runtime: runtimeB)
        await engineA.installShard(
            MockShard(totalLayers: 4, ownedInterval: LayerInterval(nodeId: "node-a", start: 0, end: 2), vocab: vocab),
            tokenizer: StubTokenizer(), modelId: "mock", eosTokenIds: [])
        await engineB.installShard(
            MockShard(totalLayers: 4, ownedInterval: LayerInterval(nodeId: "node-b", start: 2, end: 4), vocab: vocab),
            tokenizer: StubTokenizer(), modelId: "mock", eosTokenIds: [])

        let req = ChatCompletionRequest(model: "mock", messages: [ChatMessage(role: "user", content: "hi")], max_tokens: 3)

        // Run both ranks; collect the tail's streamed chunks.
        async let aStream: Void = { for await _ in await engineA.submit(request: req, requestId: "r1") {} }()
        var chunks: [String] = []
        for await ev in await engineB.submit(request: req, requestId: "r1") {
            if case .chunk(let s) = ev { chunks.append(s) }
        }
        await aStream

        // The tail streamed exactly max_tokens chunks (greedy, deterministic).
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { $0.hasPrefix("t") })
    }
}
