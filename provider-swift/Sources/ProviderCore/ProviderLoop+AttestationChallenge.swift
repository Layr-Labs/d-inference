/// ProviderLoop -- attestation + code-identity (APNs) challenge responses.
///
/// Answers coordinator attestation challenges (live model-hash binding) and
/// the APNs-delivered code-identity challenge.

import CryptoKit
import Foundation
import InferenceWorkerProtocol

extension ProviderLoop {
    // MARK: - Attestation Challenge

    internal func handleAttestationChallenge(
        nonce: String,
        timestamp: String,
        send: SendHandle,
        processEvidenceContext: ProcessEvidenceResponseContext? = nil
    ) async -> Bool {
        logger.info(.attestationChallengeReceived)

        guard let builder = attestationBuilder else {
            logger.warning(.attestationIdentityUnavailable)
            return false
        }

        do {
            let snapshot = try await inferenceWorkerClient.capacitySnapshot()
            guard snapshot.launchIdentifier == inferenceWorkerIdentity?.launchIdentifier else {
                throw InferenceWorkerClientError.invalidated
            }
            let loadedEntries = snapshot.entries.filter {
                $0.state == 2 && $0.manifestSHA256 != nil
            }
            let loadedModelHashes = Dictionary(uniqueKeysWithValues:
                loadedEntries.compactMap { entry in
                    entry.manifestSHA256.map { (entry.modelIdentifier, $0) }
                })
            let activeModelHash = (
                loadedEntries.first(where: { $0.activeRequests > 0 })
                    ?? loadedEntries.first
            )?.manifestSHA256

            guard let workerPublicKey = workerProcessPublicKeyBase64 else { return false }
            let response = try builder.buildChallengeResponse(
                nonce: nonce,
                timestamp: timestamp,
                providerPublicKey: workerPublicKey,
                binaryHash: binaryHash,
                activeModelHash: activeModelHash,
                runtimeHashes: augmentRuntimeHashesWithMetallib(loopConfig.runtimeHashes),
                modelHashes: loadedModelHashes,
                processEvidenceContext: processEvidenceContext
            )

            send.send(.attestationResponse(AttestationResponsePayload(
                nonce: response.nonce,
                signature: response.signature,
                statusSignature: response.statusSignature,
                processEvidenceSignature: response.processEvidenceSignature,
                publicKey: response.publicKey,
                processEvidenceVersion: response.processEvidenceVersion,
                coordinatorSessionId: response.coordinatorSessionId,
                challengeGeneration: response.challengeGeneration,
                challengeExpiresAt: response.challengeExpiresAt,
                sePublicKey: response.sePublicKey,
                serialNumber: response.serialNumber,
                providerVersion: response.providerVersion,
                providerPlatform: response.providerPlatform,
                providerBackend: response.providerBackend,
                metallibHash: response.metallibHash,
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

            logger.info(.attestationResponseSent)
            return true
        } catch {
            logger.error(.attestationSigningFailed)
            logger.error("Failed to sign attestation challenge: \(error)")
        }
        return false
    }

    internal func handleProcessEvidenceChallenge(
        _ challenge: CoordinatorMessage.AttestationChallenge,
        send: SendHandle
    ) async -> Bool {
        let runtimeHashes = augmentRuntimeHashesWithMetallib(loopConfig.runtimeHashes)
        guard challenge.processEvidenceVersion == ProcessEvidenceProtocol.version,
              let coordinatorSessionId = challenge.coordinatorSessionId,
              let challengeGeneration = challenge.challengeGeneration,
              let challengeExpiresAt = challenge.challengeExpiresAt,
              let metallibHash = runtimeHashes?.templateHashes["mlx_metallib"],
              !coordinatorSessionId.isEmpty,
              !challengeGeneration.isEmpty,
              !challengeExpiresAt.isEmpty,
              !metallibHash.isEmpty
        else {
            logger.error("Rejected incomplete or unsupported process evidence challenge")
            return false
        }
        let context = ProcessEvidenceResponseContext(
            version: ProcessEvidenceProtocol.version,
            coordinatorSessionId: coordinatorSessionId,
            challengeGeneration: challengeGeneration,
            challengeExpiresAt: challengeExpiresAt,
            providerVersion: ProviderCore.version,
            providerPlatform: "macos-arm64",
            providerBackend: "mlx-swift",
            metallibHash: metallibHash
        )
        return await handleAttestationChallenge(
            nonce: challenge.nonce,
            timestamp: challenge.timestamp,
            send: send,
            processEvidenceContext: context
        )
    }

    // MARK: - Code-identity (APNs) challenge


    /// Extracts the code_challenge EncryptedPayload from an APNs push userInfo.
    static func extractCodeChallenge(_ userInfo: [String: Any]) -> EncryptedPayload? {
        guard let cc = userInfo["code_challenge"],
              let data = try? JSONSerialization.data(withJSONObject: cc)
        else {
            return nil
        }
        return try? JSONDecoder().decode(EncryptedPayload.self, from: data)
    }

    /// Requests a domain-specific, launch/certification-bound proof. The worker
    /// validates the decrypted nonce shape and signs it with the shared
    /// persistent Secure Enclave identity; no generic plaintext payload crosses
    /// XPC and the supervisor only forwards the typed proof fields.
    func handleCodeChallenge(_ challenge: EncryptedPayload, send: SendHandle) async {
        guard let identity = inferenceWorkerIdentity,
              certifiedConnectionGeneration == coordinatorConnectionGeneration,
              let senderKey = Data(base64Encoded: challenge.ephemeralPublicKey),
              let ciphertext = Data(base64Encoded: challenge.ciphertext),
              let request = WorkerCodeChallengeRequest(
                launchIdentifier: identity.launchIdentifier,
                connectionGeneration: coordinatorConnectionGeneration,
                senderPublicKey: senderKey,
                ciphertext: ciphertext) else {
            logger.warning(.codeAttestationSignerUnavailable)
            return
        }
        do {
            let proof = try await inferenceWorkerClient.answerCodeChallenge(request)
            guard proof.launchIdentifier == identity.launchIdentifier,
                  proof.connectionGeneration == coordinatorConnectionGeneration,
                  let nonceBytes = Data(base64Encoded: proof.nonce),
                  nonceBytes.count == 32 else {
                throw InferenceWorkerClientError.invalidFrame
            }
            var binding = Data("darkbloom/code-challenge-proof/v1\u{0}".utf8)
            binding.append(Data(identity.launchIdentifier.utf8))
            var generation = coordinatorConnectionGeneration.bigEndian
            withUnsafeBytes(of: &generation) { binding.append(contentsOf: $0) }
            binding.append(nonceBytes)
            guard sha256Hex(binding) == proof.bindingDigest else {
                throw InferenceWorkerClientError.invalidFrame
            }
            send.send(.codeAttestationResponse(
                nonce: proof.nonce,
                signature: proof.signature))
            logger.info(.codeAttestationResponseSent)
        } catch {
            logger.error(.codeAttestationSigningFailed)
        }
    }

}
