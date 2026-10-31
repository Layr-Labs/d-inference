import CryptoKit
import Darwin
import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity

/// Shared material for two distinct private protocols. Callers validate their
/// complete scope first and supply the installed owner's current-selection check.
enum GLM5NextCalibrationMemberAuthorization {
    enum Purpose {
        case experiment, quotation
        var domain: Data {
            switch self {
            case .experiment: return Data("darkbloom/glm-worker-calibration/v1\0".utf8)
            case .quotation: return Data("darkbloom/glm-calibration-quote/v1\0".utf8)
            }
        }
        var filename: String {
            switch self {
            case .experiment: return "glm-calibration"
            case .quotation: return "glm-calibration-quote"
            }
        }
    }
    struct Material {
        let document: Data
        let credentialInput: Data
    }

    static func sign(payload: Data, purpose: Purpose, epoch: UUID, rank: Int,
                     memberIdentity: Data, peerIdentity: Data, signer: any AttestationSigner,
                     verifySelection: () throws -> Void) throws -> Material {
        guard (0...1).contains(rank), !payload.isEmpty, payload.count <= 128 << 10,
              let raw = Data(base64Encoded: signer.publicKeyBase64), raw.count == 64,
              Data([4]) + raw == memberIdentity, memberIdentity != peerIdentity else {
            throw GLM5NextCalibrationDocument.invalid("Signer or payload differs from authenticated selection")
        }
        let key = try P256.Signing.PublicKey(x963Representation: memberIdentity)
        _ = try ClusterDataPlanePin(identityPublicKey: peerIdentity)
        try verifySelection()
        let message = purpose.domain + payload
        let signature = try P256.Signing.ECDSASignature(derRepresentation: signer.sign(message))
        guard key.isValidSignature(signature, for: message) else {
            throw GLM5NextCalibrationDocument.invalid("Member signature failed verification")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let document = try encoder.encode(GLM5NextCalibrationDocument.SignedDocument(
            payload: payload, signature: signature.rawRepresentation))
        guard document.count <= 256 << 10 else {
            throw GLM5NextCalibrationDocument.invalid("Document exceeds bound")
        }
        // Only the worker's ephemeral signing key is new. Its certificate uses
        // the already paired member signer; no replacement member is created.
        let worker = P256.Signing.PrivateKey()
        let certificateMessage = try ClusterDataPlaneCertificate.message(epoch: epoch,
            rank: rank, workerSigningPublicKey: worker.publicKey.x963Representation)
        let certificate = try P256.Signing.ECDSASignature(derRepresentation: signer.sign(certificateMessage))
        let credential = try ClusterDataPlaneCredential(epoch: epoch, rank: rank,
            workerSigningKey: worker.rawRepresentation, workerCertificate: certificate.rawRepresentation,
            memberIdentity: memberIdentity, peerPin: peerIdentity)
        let fields = credential.wireFields
        let input = try ClusterWorkerCodec.encode(ClusterWorkerDataPlaneTrust(
            membershipEpoch: epoch, rank: rank, workerSigningKey: fields.workerSigningKey,
            workerCertificate: fields.workerCertificate, memberIdentity: fields.memberIdentity,
            peerPin: fields.peerPin))
        return Material(document: document, credentialInput: input)
    }

    /// Caller revalidates expiry/scope before writing. Never persists credentials,
    /// creates a directory, or replaces an existing document.
    static func write(document: Data, purpose: Purpose, directory: URL) throws -> URL {
        guard !document.isEmpty, document.count <= 256 << 10 else {
            throw GLM5NextCalibrationDocument.invalid("Document exceeds bound")
        }
        let directoryHandle = try ClusterConfigurationFiles.directory(directory, privateMode: true)
        let parent = directoryHandle.descriptor
        defer { close(parent) }
        let name = "\(purpose.filename)-\(UUID().uuidString.lowercased()).json"
        let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw GLM5NextCalibrationDocument.invalid("Cannot create document") }
        var complete = false
        defer { close(fd); if !complete { unlinkat(parent, name, 0) } }
        try document.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw GLM5NextCalibrationDocument.invalid("Document write failed") }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw GLM5NextCalibrationDocument.invalid("Document sync failed") }
        try directoryHandle.check()
        complete = true
        return directory.appendingPathComponent(name)
    }
}
