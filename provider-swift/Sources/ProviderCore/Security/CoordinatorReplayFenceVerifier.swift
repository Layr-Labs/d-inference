import CryptoKit
import Foundation

public enum CoordinatorReplayFenceVerifierError: Error, Sendable, Equatable {
    case invalidPublicKey
}

/// Session-bound verifier constructed only from the P-256 key carried by the
/// accepted register ACK. A replay-fence proof is never trusted merely because
/// its identity fields or wall-clock age look plausible.
public struct P256CoordinatorReplayFenceProofVerifier:
    CoordinatorReplayFenceProofVerifier, @unchecked Sendable
{
    public let publicKeyRawRepresentation: Data
    private let publicKey: P256.Signing.PublicKey

    public init(base64EncodedPublicKey: String) throws {
        guard
            let raw = Data(base64Encoded: base64EncodedPublicKey),
            raw.base64EncodedString() == base64EncodedPublicKey,
            let key = try? P256.Signing.PublicKey(rawRepresentation: raw)
        else {
            throw CoordinatorReplayFenceVerifierError.invalidPublicKey
        }
        publicKeyRawRepresentation = raw
        publicKey = key
    }

    public init(rawRepresentation: Data) throws {
        guard let key = try? P256.Signing.PublicKey(rawRepresentation: rawRepresentation) else {
            throw CoordinatorReplayFenceVerifierError.invalidPublicKey
        }
        publicKeyRawRepresentation = rawRepresentation
        publicKey = key
    }

    public func verifyCoordinatorReplayFenceProof(
        _ proof: CoordinatorReplayFenceProof
    ) throws -> Bool {
        guard
            let signature = try? P256.Signing.ECDSASignature(
                derRepresentation: proof.coordinatorSignature)
        else {
            return false
        }
        return publicKey.isValidSignature(
            signature,
            for: proof.proofDigest.bytes
        )
    }
}
