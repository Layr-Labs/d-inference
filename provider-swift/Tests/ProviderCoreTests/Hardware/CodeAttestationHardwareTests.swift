import Foundation
import Testing
@testable import ProviderCore

@Suite(
    "Code attestation (hardware)",
    .enabled(
        if: LiveInferenceFixtures.gateEnabled("DARKBLOOM_HARDWARE_TESTS"),
        "set DARKBLOOM_HARDWARE_TESTS=1 to run Secure Enclave tests"))
struct CodeAttestationHardwareTests {
    @Test("decrypts and signs a coordinator challenge with Secure Enclave")
    func codeChallengeDecryptSignRoundTrip() throws {
        let provider = NodeKeyPair.generate()
        let coordinator = NodeKeyPair.generate()
        let ephemeralSigner = try SecureEnclaveIdentity.createEphemeral()
        let signer = try #require(
            ephemeralSigner,
            "DARKBLOOM_HARDWARE_TESTS requires an available Secure Enclave signer")

        let nonceB64 = Data("0123456789abcdef0123456789abcdef".utf8).base64EncodedString()

        let providerPublicKey = try #require(Data(base64Encoded: provider.publicKeyBase64))
        let challenge = try coordinator.encryptPayload(
            recipientPublicKey: providerPublicKey,
            plaintext: Data(nonceB64.utf8))

        let answer = try ProviderLoop.answerCodeChallenge(
            challenge: challenge,
            keyPair: provider,
            signer: signer)
        #expect(answer.nonce == nonceB64)

        let signature = try #require(Data(base64Encoded: answer.signature))
        let signerPublicKey = try #require(Data(base64Encoded: signer.publicKeyBase64))
        #expect(
            SecureEnclaveIdentity.verify(
                signature: signature,
                for: Data(nonceB64.utf8),
                publicKey: signerPublicKey))

        let attacker = NodeKeyPair.generate()
        #expect(throws: (any Error).self) {
            _ = try ProviderLoop.answerCodeChallenge(
                challenge: challenge,
                keyPair: attacker,
                signer: signer)
        }
    }
}
