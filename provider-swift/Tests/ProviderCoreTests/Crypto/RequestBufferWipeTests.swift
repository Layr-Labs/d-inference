import CryptoKit
import Foundation
import Testing
@testable import ProviderCore

/// Plaintext that `NodeKeyPair` opens or seals is zeroed when its buffer is
/// released, so a finished request leaves no copy of it in freed memory. The
/// test reads its own process memory after each step.
@Suite(.serialized) struct RequestBufferWipeTests {
    /// Large enough that the allocator does not clear the block itself on free.
    static let bodySize = 256 * 1024

    @Test func openedAndSealedPlaintextIsZeroedWhenReleased() throws {
        let prompt = UnheldText.random(count: 32)
        let completion = UnheldText.random(count: 32)
        let provider = NodeKeyPair.generate()
        let coordinator = NodeKeyPair.generate()

        var bodyDigest: SHA256Digest?
        let sealed = try prompt.withRepeated(
            prefix: #"{"model":"m","messages":[{"role":"user","content":""#, suffix: #""}]}"#,
            size: Self.bodySize
        ) { body in
            bodyDigest = SHA256.hash(data: UnsafeRawBufferPointer(body))
            return try coordinator.encrypt(
                recipientPublicKey: provider.publicKeyBytes,
                plaintext: Data(bytesNoCopy: body.baseAddress!, count: body.count, deallocator: .none))
        }
        expectNoCopies(of: prompt, after: "sealing the request")

        do { // `body` is released before the scan.
            let body = try provider.decrypt(senderPublicKey: coordinator.publicKeyBytes, ciphertext: sealed)
            #expect(SHA256.hash(data: body) == bodyDigest)
        }
        expectNoCopies(of: prompt, after: "opening the request")

        let sharedKey = try provider.precomputeSharedKey(recipientPublicKey: coordinator.publicKeyBytes)
        let payload = try completion.withRepeated(
            prefix: #"data: {"choices":[{"delta":{"content":""#, suffix: "\"}}]}\n\n",
            size: Self.bodySize
        ) { chunk in
            try provider.encryptPayloadFast(
                sharedKey: sharedKey,
                plaintext: Data(bytesNoCopy: chunk.baseAddress!, count: chunk.count, deallocator: .none))
        }
        expectNoCopies(of: completion, after: "sealing the response")

        // The scan finds each text while a buffer still holds it.
        let reopened = try provider.decrypt(senderPublicKey: coordinator.publicKeyBytes, ciphertext: sealed)
        withExtendedLifetime(reopened) { #expect(!ProcessMemoryScan.copies(of: prompt).isEmpty) }
        let chunk = try coordinator.decrypt(
            senderPublicKey: provider.publicKeyBytes, ciphertext: try #require(Data(base64Encoded: payload.ciphertext)))
        withExtendedLifetime(chunk) { #expect(!ProcessMemoryScan.copies(of: completion).isEmpty) }
    }

    private func expectNoCopies(
        of text: UnheldText, after step: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let copies = ProcessMemoryScan.copies(of: text)
        if let first = copies.first {
            Issue.record("\(copies.count) copies in memory after \(step), first at \(first)",
                         sourceLocation: sourceLocation)
        }
    }
}
