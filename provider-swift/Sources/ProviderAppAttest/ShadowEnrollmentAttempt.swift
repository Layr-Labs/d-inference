import Foundation

/// Retains one original enrollment transcript after Apple's serverUnavailable.
/// This hash is used only for attestation, never for fresh serving assertions.
/// The coordinator validates its original transaction and requires a subsequent
/// assertion encrypted to this process's current endpoint before authorization.
public struct ShadowEnrollmentAttempt: Codable, Sendable {
    let keyID: String
    let clientHash: Data
    let session: String
    let protocolVersion: Int?
    let status: AppAttestStatus?
    let createdAt: Date

    func canResume(keyID: String, session: String, protocolVersion: Int?, now: Date) -> Bool {
        // Protocol 3 has a durable enrollment context for cross-session replay;
        // an attempt recorded under any other protocol is never resumed.
        guard self.keyID == keyID, clientHash.count == 32,
              self.session.utf8.count == 44, Data(base64Encoded: self.session)?.count == 32,
              createdAt <= now, now.timeIntervalSince(createdAt) <= 86400,
              self.protocolVersion == 3, protocolVersion == 3 else { return false }
        return true
    }
}
