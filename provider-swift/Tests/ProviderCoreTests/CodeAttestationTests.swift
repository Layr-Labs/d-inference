import Foundation
import Testing
@testable import ProviderCore

// Provider side of the APNs code-identity round-trip: decrypt E_K(nonce) with K
// and sign the recovered nonce with the SE key. Mirrors exactly what the
// coordinator builds (E_K via the inference E2E path) and verifies
// (VerifyChallengeSignature over the nonce against the SE key). No device needed.
@Test func codeChallengeDecryptSignRoundTrip() throws {
    let provider = NodeKeyPair.generate()    // the provider's K
    let coordinator = NodeKeyPair.generate() // stands in for the coordinator's ephemeral sender
    guard let signer = try SecureEnclaveIdentity.createEphemeral() else {
        // No SE/CryptoKit signer available in this environment — nothing to test.
        return
    }

    let nonceB64 = Data("0123456789abcdef0123456789abcdef".utf8).base64EncodedString()

    // Coordinator builds E_K(nonceB64) to the provider's public key, exactly like
    // the Go BuildCodeChallengePayload does via internal/e2e.Encrypt.
    let providerPub = try #require(Data(base64Encoded: provider.publicKeyBase64))
    let challenge = try coordinator.encryptPayload(recipientPublicKey: providerPub, plaintext: Data(nonceB64.utf8))

    // Provider answers: decrypt with K, sign the nonce with the SE key.
    let answer = try ProviderLoop.answerCodeChallenge(challenge: challenge, keyPair: provider, signer: signer)
    #expect(answer.nonce == nonceB64)

    // The signature must verify over the nonce bytes against the SE public key —
    // exactly what the coordinator's attestation.VerifyChallengeSignature checks.
    let sigData = try #require(Data(base64Encoded: answer.signature))
    let pubData = try #require(Data(base64Encoded: signer.publicKeyBase64))
    #expect(SecureEnclaveIdentity.verify(signature: sigData, for: Data(nonceB64.utf8), publicKey: pubData))

    // A wrong key (different provider K) must NOT decrypt the challenge.
    let attacker = NodeKeyPair.generate()
    #expect(throws: (any Error).self) {
        _ = try ProviderLoop.answerCodeChallenge(challenge: challenge, keyPair: attacker, signer: signer)
    }
}

@Test func extractCodeChallengeParsesPushPayload() throws {
    let userInfo: [String: Any] = [
        "aps": ["content-available": 1],
        "code_challenge": ["ephemeral_public_key": "ZXBo", "ciphertext": "Y2lwaA=="],
    ]
    let cc = ProviderLoop.extractCodeChallenge(userInfo)
    #expect(cc?.ephemeralPublicKey == "ZXBo")
    #expect(cc?.ciphertext == "Y2lwaA==")

    // Missing code_challenge → nil (the handler then no-ops, fail-closed).
    #expect(ProviderLoop.extractCodeChallenge(["aps": ["content-available": 1]]) == nil)
}
