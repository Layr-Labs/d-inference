/// ProviderLoop -- attestation + code-identity (APNs) challenge responses.
///
/// Answers coordinator attestation challenges (live model-hash binding) and
/// the APNs-delivered code-identity challenge.

import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXLMServer
import MLXVLM
#if canImport(os)
import os
#endif

extension ProviderLoop {
    // MARK: - Attestation Challenge

    internal func handleAttestationChallenge(
        nonce: String,
        timestamp: String,
        send: SendHandle
    ) async {
        logger.info("Handling attestation challenge (timestamp: \(timestamp))")

        guard let builder = attestationBuilder else {
            logger.warning("No Secure Enclave identity -- cannot respond to attestation challenge")
            return
        }

        do {
            let activeModelHash: String?
            if let modelId = state.currentModel {
                activeModelHash = liveModelHashes[modelId]
            } else {
                activeModelHash = nil
            }

            // Report hashes ONLY for models we are CURRENTLY SERVING (a live
            // slot this session), never for every advertised model. Registration
            // still advertises all models' startup hashes (the coordinator's
            // catalog routing filter needs them, and a stale IDLE model there
            // degrades to a gentle silent deroute). But the challenge response
            // feeds the coordinator's model-swap *hard-untrust* check: reporting
            // a hash for an idle, unloaded model would hard-untrust this provider
            // the moment that model's catalog hash changes (e.g. a re-publish)
            // before we re-download it — even though we never served stale
            // weights. A model that has been idle-unloaded drops out
            // automatically here because it no longer has a slot.
            let loadedModelHashes = loadedModelHashesSnapshot()

            let response = try builder.buildChallengeResponse(
                nonce: nonce,
                timestamp: timestamp,
                providerPublicKey: keyPair.publicKeyBase64,
                binaryHash: binaryHash,
                activeModelHash: activeModelHash,
                runtimeHashes: augmentRuntimeHashesWithMetallib(loopConfig.runtimeHashes),
                modelHashes: loadedModelHashes
            )

            send.send(.attestationResponse(AttestationResponsePayload(
                nonce: response.nonce,
                signature: response.signature,
                statusSignature: response.statusSignature,
                publicKey: response.publicKey,
                hypervisorActive: response.hypervisorActive,
                rdmaDisabled: response.rdmaDisabled,
                sipEnabled: response.sipEnabled,
                secureBootEnabled: response.secureBootEnabled,
                binaryHash: response.binaryHash,
                activeModelHash: response.activeModelHash,
                pythonHash: response.pythonHash,
                runtimeHash: response.runtimeHash,
                templateHashes: response.templateHashes,
                modelHashes: response.modelHashes
            )))

            logger.info("Attestation challenge response sent")
        } catch {
            logger.error("Failed to sign attestation challenge: \(error)")
        }
    }

    // MARK: - Code-identity (APNs) challenge

    /// Decrypts an E_K(nonce) code-identity challenge and produces the WebSocket
    /// reply: the recovered nonce (proof of K-possession) + Sign_SE(nonce). Pure
    /// and testable. K (NodeKeyPair, X25519) is decrypt-only — the signature is
    /// the separate Secure-Enclave P-256 key. The coordinator verifies both
    /// (nonce equality + the SE signature against the registration-bound SE key).
    static func answerCodeChallenge(
        challenge: EncryptedPayload,
        keyPair: NodeKeyPair,
        signer: any AttestationSigner
    ) throws -> (nonce: String, signature: String) {
        let nonceData = try keyPair.decryptPayload(challenge)
        guard let nonceB64 = String(data: nonceData, encoding: .utf8) else {
            throw NSError(domain: "ProviderCore.codeAttest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "decrypted code-challenge nonce is not UTF-8"])
        }
        let sig = try signer.sign(Data(nonceB64.utf8))
        return (nonceB64, sig.base64EncodedString())
    }

    /// Extracts the code_challenge EncryptedPayload from an APNs push userInfo.
    static func extractCodeChallenge(_ userInfo: [String: Any]) -> EncryptedPayload? {
        guard let cc = userInfo["code_challenge"],
              let data = try? JSONSerialization.data(withJSONObject: cc)
        else {
            return nil
        }
        return try? JSONDecoder().decode(EncryptedPayload.self, from: data)
    }

    /// Handles an inbound APNs code-identity challenge (delivered by the app
    /// delegate): decrypt E_K(nonce) with K, sign the nonce with the SE key, and
    /// reply over the WebSocket. Only the genuine hardened process can do both,
    /// which is what binds the Apple-gated push proof onto this connection.
    func handleCodeChallenge(_ challenge: EncryptedPayload, send: SendHandle) {
        guard let signer = self.signer else {
            logger.warning("code-identity challenge received but no Secure Enclave signer is available")
            return
        }
        do {
            let answer = try Self.answerCodeChallenge(challenge: challenge, keyPair: keyPair, signer: signer)
            send.send(.codeAttestationResponse(nonce: answer.nonce, signature: answer.signature))
            logger.info("code-identity challenge answered over WebSocket")
        } catch {
            logger.error("failed to answer code-identity challenge: \(error)")
        }
    }

}
