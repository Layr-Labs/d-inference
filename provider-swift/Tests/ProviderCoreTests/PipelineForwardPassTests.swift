import CryptoKit
import Foundation
import MLX
import Testing

@testable import ProviderCore

/// End-to-end verification of the encrypted pipeline forward pass, runnable on
/// ONE machine: two ranks run in-process over a loopback transport, and the
/// distributed result must equal running every layer on a single rank.
///
/// The MLX ops here run on CPU and are deliberately trivial — the point is to
/// prove the PLUMBING (embed → layers → encode → AEAD-seal → transport → open →
/// decode → layers → logits) is correct and lossless, and that a tampered frame
/// is rejected. The real two-Mac ring (MLXDistributed) is Spike A on hardware.
@Suite("PipelineForwardPass")
struct PipelineForwardPassTests {

    private struct SoftSigner: AttestationSigner {
        let pk = P256.Signing.PrivateKey()
        func sign(_ d: Data) throws -> Data { try pk.signature(for: d).derRepresentation }
        var publicKeyBase64: String { pk.publicKey.rawRepresentation.base64EncodedString() }
    }

    private func sessions() throws -> (ClusterSession, ClusterSession) {
        let a = SoftSigner(); let b = SoftSigner()
        let members = [
            ClusterMember(nodeId: "node-a", sePublicKeyBase64: a.publicKeyBase64,
                          x25519PublicKeyBase64: NodeKeyPair.generate().publicKeyBase64, trustLevel: "hardware"),
            ClusterMember(nodeId: "node-b", sePublicKeyBase64: b.publicKeyBase64,
                          x25519PublicKeyBase64: NodeKeyPair.generate().publicKeyBase64, trustLevel: "hardware"),
        ]
        let body = ClusterRosterBody(clusterId: "c1", members: members,
                                     issuedAt: Date(timeIntervalSince1970: 0),
                                     expiresAt: Date(timeIntervalSince1970: 1e12))
        let ini = ClusterHandshakeInitiator(clusterId: "c1", localNodeId: "node-a", signer: a, roster: body)
        let res = ClusterHandshakeResponder(localNodeId: "node-b", signer: b, roster: body)
        let m1 = ini.start(); let m2 = try res.respond(m1); let (m3, sa) = try ini.finish(m2)
        let sb = try res.confirm(m3)
        return (sa, sb)
    }

    // Per-rank stand-in transforms + their monolithic composition.
    private func layers0(_ h: MLXArray) -> MLXArray { h * 2.0 + 1.0 }
    private func layers1(_ h: MLXArray) -> MLXArray { h * 3.0 }

    @Test func activationCodecRoundTrip() throws {
        let x = MLXArray(converting: (0..<24).map { Double($0) * 0.5 - 3.0 }, [2, 3, 4]).asType(DType.float16)
        let y = try ActivationCodec.decode(try ActivationCodec.encode(x))
        #expect(y.shape == [2, 3, 4])
        #expect(y.dtype == DType.float16)
        let dx = x.asType(DType.float32).asArray(Float.self)
        let dy = y.asType(DType.float32).asArray(Float.self)
        #expect(zip(dx, dy).allSatisfy { abs($0 - $1) < 1e-3 })
    }

    @Test func twoRankEncryptedPipelineEqualsMonolithic() async throws {
        let (sa, sb) = try sessions()
        let plan = try LayerPartition.partition(totalLayers: 48, nodes: [
            .init(nodeId: "node-a", weightBytes: 28 << 30),
            .init(nodeId: "node-b", weightBytes: 20 << 30),
        ])

        let mailbox = LoopbackMailbox()
        let stage0 = PipelineStage(
            config: .init(rank: 0, worldSize: 2, interval: plan[0], prevRank: nil, nextRank: 1),
            transport: LoopbackPipelineTransport(mailbox: mailbox, selfRank: 0),
            sealing: ClusterSealingChannel(key: sa.sendKey()), opening: nil)
        let stage1 = PipelineStage(
            config: .init(rank: 1, worldSize: 2, interval: plan[1], prevRank: 0, nextRank: nil),
            transport: LoopbackPipelineTransport(mailbox: mailbox, selfRank: 1),
            sealing: nil, opening: ClusterOpeningChannel(key: sb.recvKey()))

        let input = MLXArray(converting: (0..<12).map { Double($0) - 6.0 }, [1, 12])

        async let r0: MLXArray? = stage0.runStep(
            headInput: input, clusterId: "c1", requestId: "req-1", seq: 0, runLayers: layers0)
        async let r1: MLXArray? = stage1.runStep(
            headInput: nil, clusterId: "c1", requestId: "req-1", seq: 0, runLayers: layers1)
        let head = try await r0
        let tail = try await r1

        #expect(head == nil)                 // head sent its output downstream
        let got = try #require(tail).asArray(Float.self)
        let want = layers1(layers0(input)).asArray(Float.self)
        #expect(zip(got, want).allSatisfy { abs($0 - $1) < 1e-4 })
    }

    @Test func tamperedFrameRejected() throws {
        let (sa, sb) = try sessions()
        let seal0 = ClusterSealingChannel(key: sa.sendKey())
        let open1 = ClusterOpeningChannel(key: sb.recvKey())
        let ctx = ClusterFrameContext(clusterId: "c1", requestId: "r", layerRange: "0..28", seq: 0)
        let frame = try seal0.seal(
            ActivationCodec.encode(MLXArray(converting: [1.0, 2.0, 3.0]).asType(DType.float32)), context: ctx)
        var tampered = frame; tampered[tampered.count - 1] ^= 0x01
        #expect(throws: (any Error).self) { _ = try open1.open(tampered, context: ctx) }
    }
}
