import Foundation
import Testing

@testable import ProviderCore

/// Keys and expected bytes shared with the coordinator's tests
/// (`coordinator/tests/internal/inference/responseseq`), produced by Go's
/// `nacl/box.SealAfterPrecomputation`: both sides seal and open the same bytes.
private enum SharedResponseVector {
    static let providerSecretHex = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
    static let consumerSecretHex = "a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0"
    static let prefix: [UInt8] = Array(0x10...0x1f)
    static let frame2Plaintext = "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n"
    static let frame2Ciphertext =
        "EBESExQVFhcYGRobHB0eHwAAAAAAAAAC6qbPyOrEHEnEBuSMnuj2DjjR1FbQgtDp8WMvw0BuKaV3IPXgXwwu+PocsthsKiZ65eL9bHnAhuY1Ol3iEbTjfg=="
    static let usage = UsageInfo(
        promptTokens: 128, completionTokens: 21, reasoningTokens: 5, cacheOutcome: .hit, cachedTokens: 64)
    static let usage3Ciphertext =
        "EBESExQVFhcYGRobHB0eHwAAAAAAAAADO91Acu/lNRkPlrB1KS/yexVl7elPqagglSwja8RBWbb2muCAwCGlbQVKRdLL4wA/yHcFw7IfaDM4aw2skaCstdlkl2Mrxo3AFm1f+TbNA39iBDn2Ey98jVYJiyA39zDabrgMdZNj4itzDKK/vfujlRAYGwc1OaIQnUQFvoG6t/j/J8QEf+52vAYOq7WipbSCcRgj4A=="
}

/// The 24-byte nonce at the front of a sealed payload, split into the
/// request's prefix and the frame number.
func responseFrameNumber(_ payload: EncryptedPayload) throws -> (prefix: [UInt8], number: UInt64) {
    let sealed = try #require(Data(base64Encoded: payload.ciphertext))
    try #require(sealed.count >= 24)
    let nonce = [UInt8](sealed.prefix(24))
    let number = nonce[16..<24].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    return (Array(nonce[0..<16]), number)
}

/// A sealer for a fresh provider key, sealing to a fresh consumer key.
private func makeSealer() throws -> (ResponseFrameSealer, provider: NodeKeyPair, consumer: NodeKeyPair) {
    let provider = NodeKeyPair.generate()
    let consumer = NodeKeyPair.generate()
    let sealer = ResponseFrameSealer(
        keyPair: provider, sharedKey: try provider.precomputeSharedKey(recipientPublicKey: consumer.publicKeyBytes))
    return (sealer, provider, consumer)
}

@Suite("Response frame sealer")
struct ResponseFrameSealerTests {
    @Test("frames are numbered from 0 under one prefix and open as ordinary boxes")
    func framesCountUpUnderOnePrefix() throws {
        let (sealer, provider, consumer) = try makeSealer()

        for index in 0..<5 {
            let payload = try sealer.sealFrame(Data("frame \(index)".utf8))
            let (prefix, number) = try responseFrameNumber(payload)
            #expect(prefix == sealer.prefix)
            #expect(number == UInt64(index))
            #expect(payload.ephemeralPublicKey == provider.publicKeyBase64)
            #expect(String(decoding: try consumer.decryptPayload(payload), as: UTF8.self) == "frame \(index)")
        }
    }

    @Test("the usage is sealed after the last frame and carries the frame count")
    func usageFollowsTheLastFrame() throws {
        let (sealer, _, consumer) = try makeSealer()
        for _ in 0..<3 { _ = try sealer.sealFrame(Data("x".utf8)) }

        let usage = UsageInfo(promptTokens: 10, completionTokens: 3)
        let payload = try sealer.sealUsage(usage)
        let (prefix, number) = try responseFrameNumber(payload)
        #expect(prefix == sealer.prefix)
        #expect(number == 3)
        let opened = try JSONDecoder().decode(SealedResponseUsage.self, from: consumer.decryptPayload(payload))
        #expect(opened == SealedResponseUsage(frameCount: 3, usage: usage))
    }

    @Test("a request with no frames seals its usage as number 0")
    func usageOfAnEmptyResponse() throws {
        let (sealer, _, consumer) = try makeSealer()
        let payload = try sealer.sealUsage(UsageInfo(promptTokens: 4, completionTokens: 0))
        #expect(try responseFrameNumber(payload).number == 0)
        let opened = try JSONDecoder().decode(SealedResponseUsage.self, from: consumer.decryptPayload(payload))
        #expect(opened.frameCount == 0)
    }

    @Test("each request draws its own prefix")
    func prefixesDiffer() throws {
        let provider = NodeKeyPair.generate()
        let shared = try provider.precomputeSharedKey(recipientPublicKey: NodeKeyPair.generate().publicKeyBytes)
        let first = ResponseFrameSealer(keyPair: provider, sharedKey: shared)
        let second = ResponseFrameSealer(keyPair: provider, sharedKey: shared)
        #expect(first.prefix.count == ResponseFrameSealer.prefixLength)
        #expect(first.prefix != second.prefix)
    }

    @Test("a frame and the usage match the bytes the coordinator's tests open")
    func sharedVector() throws {
        let provider = try NodeKeyPair(rawSecret: Data(hexString: SharedResponseVector.providerSecretHex))
        let consumer = try NodeKeyPair(rawSecret: Data(hexString: SharedResponseVector.consumerSecretHex))
        let sealer = ResponseFrameSealer(
            keyPair: provider,
            sharedKey: try provider.precomputeSharedKey(recipientPublicKey: consumer.publicKeyBytes),
            prefix: SharedResponseVector.prefix)

        _ = try sealer.sealFrame(Data("frame 0".utf8))
        _ = try sealer.sealFrame(Data("frame 1".utf8))
        let frame = try sealer.sealFrame(Data(SharedResponseVector.frame2Plaintext.utf8))
        #expect(frame.ciphertext == SharedResponseVector.frame2Ciphertext)

        let usage = try sealer.sealUsage(SharedResponseVector.usage)
        #expect(usage.ciphertext == SharedResponseVector.usage3Ciphertext)
        let opened = try JSONDecoder().decode(SealedResponseUsage.self, from: consumer.decryptPayload(usage))
        #expect(opened == SealedResponseUsage(frameCount: 3, usage: SharedResponseVector.usage))
    }
}
