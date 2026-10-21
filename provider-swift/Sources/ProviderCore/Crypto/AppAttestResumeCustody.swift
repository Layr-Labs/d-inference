import CryptoKit
import Foundation

extension NodeKeyPair {
    /// Answer only the endpoint-resumption transcript for this process and socket.
    /// A response proves key custody, not local authorization to accept inference.
    public func appAttestResumeResponse(
        to challenge: AppAttestResumeChallenge,
        clientNonce: String,
        now: Date = Date()
    ) throws -> AppAttestResumeResponse {
        guard challenge.protocolVersion == 1, challenge.action == "challenge" else {
            throw AppAttestResumeError.invalidMessage
        }
        _ = try AppAttestResumeWire.canonicalBase64(challenge.id, count: 32)
        _ = try AppAttestResumeWire.canonicalBase64(clientNonce, count: 32)
        let sender = try AppAttestResumeWire.canonicalBase64(
            challenge.encryptedChallenge.ephemeralPublicKey, count: 32)
        let ciphertext = try AppAttestResumeWire.ciphertext(challenge.encryptedChallenge.ciphertext)
        let plaintext = try decrypt(senderPublicKey: sender, ciphertext: ciphertext)
        let request = try AppAttestResumeWire.object(plaintext, keys: [
            "domain", "id", "instance", "connection", "client_nonce", "account", "record",
            "identity", "endpoint", "challenge", "issued_at", "expires_at",
        ])
        for field in ["id", "instance", "client_nonce", "record", "endpoint", "challenge"] {
            _ = try AppAttestResumeWire.canonicalBase64(AppAttestResumeWire.string(request[field]), count: 32)
        }
        for field in ["account", "identity"] {
            let value = try AppAttestResumeWire.string(request[field])
            guard value.utf8.count == 64, value.utf8.allSatisfy({
                (48...57).contains($0) || (97...102).contains($0)
            }) else { throw AppAttestResumeError.invalidMessage }
        }
        let connection = try AppAttestResumeWire.string(request["connection"])
        guard !connection.isEmpty, connection.utf8.count <= 64,
              request["domain"] == .string(AppAttestResumeWire.requestDomain),
              request["id"] == .string(challenge.id),
              request["endpoint"] == .string(publicKeyBase64),
              request["client_nonce"] == .string(clientNonce) else {
            throw AppAttestResumeError.invalidBinding
        }
        guard case .integer(let issued)? = request["issued_at"],
              case .integer(let expires)? = request["expires_at"],
              issued > 0, expires > issued, expires - issued <= 30_000 else {
            throw AppAttestResumeError.invalidMessage
        }
        let milliseconds = now.timeIntervalSince1970 * 1000
        guard milliseconds >= Double(issued), milliseconds < Double(expires) else {
            throw AppAttestResumeError.expiredChallenge
        }
        // Hash the authenticated bytes, never a re-encoding of their JSON value.
        var response = Data(AppAttestResumeWire.responseDomain.utf8)
        response.append(0)
        response.append(contentsOf: SHA256.hash(data: plaintext))
        return AppAttestResumeResponse(id: challenge.id, ciphertext: try encrypt(
            recipientPublicKey: sender, plaintext: response).base64EncodedString())
    }
}
