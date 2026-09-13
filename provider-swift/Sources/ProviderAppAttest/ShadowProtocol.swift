import CryptoKit
import Foundation

public struct ShadowEncryptedChallenge: Codable, Sendable, Equatable {
    public var ephemeralPublicKey: String
    public var ciphertext: String
    enum CodingKeys: String, CodingKey {
        case ephemeralPublicKey = "ephemeral_public_key"
        case ciphertext
    }
}

/// Mirrors coordinator/protocol/app_attest_shadow.go. Never authoritative trust.
public struct AppAttestShadowPayload: Codable, Sendable, Equatable {
    public var action: String
    public var session: String
    public var environment: String?
    public var keyID: String?
    public var challenge: String?
    public var result: String?
    public var proof: String?
    public var encryptedChallenge: ShadowEncryptedChallenge?

    public init(action: String, session: String) { self.action = action; self.session = session }
    enum CodingKeys: String, CodingKey {
        case action, session, environment, challenge, result, proof
        case keyID = "key_id"
        case encryptedChallenge = "encrypted_challenge"
    }

    public func clientHash(publicKey: String) -> Data {
        var data = Data()
        for value in ["darkbloom.app-attest.shadow.v1", action, session, environment ?? "", keyID ?? "", challenge ?? "", publicKey] {
            let bytes = Data(value.utf8)
            var length = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        return Data(SHA256.hash(data: data))
    }
}

public enum ShadowFailure: String, Error, Sendable {
    case unsupported, notConfigured = "not_configured", environmentMismatch = "environment_mismatch"
    case keychainError = "keychain_error", appleUnavailable = "apple_unavailable"
    case appleInvalidKey = "apple_invalid_key", appleError = "apple_error"
    case keyUnregistered = "key_unregistered", busy, cancelled
    case invalidRequest = "invalid_request"
}

public protocol AppAttestService: Sendable {
    func checkAvailability(environment: String) async throws
    func generateKey() async throws -> String
    func attestKey(_ id: String, hash: Data) async throws -> Data
    func generateAssertion(_ id: String, hash: Data) async throws -> Data
}

public struct ShadowKeyRecord: Codable, Sendable {
    public var keyID: String
    public var attested: Bool
    public var createdAt: Date
}

public protocol ShadowKeyStorage: Sendable {
    func load(scope: String) throws -> ShadowKeyRecord?
    func save(_ record: ShadowKeyRecord, scope: String) throws
}
