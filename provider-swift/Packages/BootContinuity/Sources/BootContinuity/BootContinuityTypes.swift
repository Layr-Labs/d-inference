import Foundation

/// Explicit development opt-in. No environment variable enables this package.
public enum BootContinuityActivation: Sendable {
    case disabled
    case experimental
}

public enum BootContinuityError: Error, Equatable, Sendable {
    case disabled
    case secureEnclaveUnavailable
    case invalidContext
    case invalidChallenge
    case invalidRecord
    case unsupportedRecordVersion
    case contextMismatch
    case publicKeyMismatch
    /// Reboot, unavailable hardware, and damaged handles can all cause this.
    /// This local result does not attest a boot transition to a remote party.
    case keyUnavailable
    case possessionCheckFailed
}

/// Exact recovery namespace. Changing any field requires a new bootstrap.
public struct BootContinuityContext: Codable, Equatable, Sendable {
    public let accountID: String
    public let deviceID: String
    public let coordinatorOrigin: String
    public let releaseID: String
    public let policyGeneration: UInt64

    public init(accountID: String, deviceID: String, coordinatorOrigin: String,
                releaseID: String, policyGeneration: UInt64) throws {
        self.accountID = accountID
        self.deviceID = deviceID
        self.coordinatorOrigin = coordinatorOrigin
        self.releaseID = releaseID
        self.policyGeneration = policyGeneration
        try validate()
    }

    func validate() throws {
        for value in [accountID, deviceID, coordinatorOrigin, releaseID] {
            guard !value.isEmpty, value.utf8.count <= 512,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw BootContinuityError.invalidContext
            }
        }
        guard let origin = URLComponents(string: coordinatorOrigin),
              origin.scheme == "https", origin.host?.isEmpty == false,
              origin.user == nil, origin.password == nil,
              origin.query == nil, origin.fragment == nil,
              origin.path.isEmpty else { throw BootContinuityError.invalidContext }
    }
}

public struct BootContinuationChallenge: Sendable {
    public let nonce: Data
    public let processPublicKey: Data

    public init(nonce: Data, processPublicKey: Data) throws {
        guard nonce.count == 32, processPublicKey.count == 32 else {
            throw BootContinuityError.invalidChallenge
        }
        self.nonce = nonce
        self.processPublicKey = processPublicKey
    }
}

/// A domain-separated local possession proof; not hardware attestation or authorization.
public struct BootContinuationProof: Sendable {
    public let publicKey: Data
    public let signatureDER: Data
    public let transcript: Data
}
