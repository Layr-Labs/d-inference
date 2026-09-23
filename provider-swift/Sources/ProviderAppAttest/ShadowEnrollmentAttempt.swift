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
        guard self.keyID == keyID, clientHash.count == 32,
              self.session.utf8.count == 44, Data(base64Encoded: self.session)?.count == 32,
              createdAt <= now, now.timeIntervalSince(createdAt) <= 86400 else { return false }
        // Only v2/v3 have durable enrollment contexts for cross-session replay.
        // A legacy exchange must not reuse its key with a different hash.
        if [2, 3].contains(self.protocolVersion ?? 0), [2, 3].contains(protocolVersion ?? 0) { return true }
        return self.protocolVersion == protocolVersion && self.session == session
    }
}
