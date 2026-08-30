import Foundation

public enum ProcessEvidenceProtocol {
    public static let version = "process_evidence_v1"
    public static let domain = "darkbloom.process_evidence"
}

/// The complete immutable process_evidence_v1 signing contract. Adding a field
/// requires a new version; deployed v1 bytes must never change meaning.
public struct ProcessEvidenceCanonicalInput: Sendable, Equatable {
    public var coordinatorNonce: String
    public var coordinatorTimestamp: String
    public var coordinatorSessionId: String
    public var challengeGeneration: String
    public var evidenceExpiresAt: String
    public var sePublicKey: String
    public var serialNumber: String
    public var processPublicKey: String
    public var binaryHash: String
    public var providerVersion: String
    public var providerPlatform: String
    public var providerBackend: String
    public var runtimeHash: String
    public var metallibHash: String
    public var sipEnabled: Bool?
    public var secureBootEnabled: Bool?

    public init(
        coordinatorNonce: String,
        coordinatorTimestamp: String,
        coordinatorSessionId: String,
        challengeGeneration: String,
        evidenceExpiresAt: String,
        sePublicKey: String,
        serialNumber: String,
        processPublicKey: String,
        binaryHash: String,
        providerVersion: String,
        providerPlatform: String,
        providerBackend: String,
        runtimeHash: String,
        metallibHash: String,
        sipEnabled: Bool?,
        secureBootEnabled: Bool?
    ) {
        self.coordinatorNonce = coordinatorNonce
        self.coordinatorTimestamp = coordinatorTimestamp
        self.coordinatorSessionId = coordinatorSessionId
        self.challengeGeneration = challengeGeneration
        self.evidenceExpiresAt = evidenceExpiresAt
        self.sePublicKey = sePublicKey
        self.serialNumber = serialNumber
        self.processPublicKey = processPublicKey
        self.binaryHash = binaryHash
        self.providerVersion = providerVersion
        self.providerPlatform = providerPlatform
        self.providerBackend = providerBackend
        self.runtimeHash = runtimeHash
        self.metallibHash = metallibHash
        self.sipEnabled = sipEnabled
        self.secureBootEnabled = secureBootEnabled
    }
}

public enum ProcessEvidenceCanonical {
    /// String fields are always encoded, including empty strings. nil posture
    /// booleans are omitted while false is encoded explicitly. JSON object keys
    /// are sorted and slashes are not escaped, exactly matching Go.
    public static func buildV1(_ input: ProcessEvidenceCanonicalInput) throws -> Data {
        var object: [String: Any] = [
            "binary_hash": input.binaryHash,
            "challenge_generation": input.challengeGeneration,
            "coordinator_nonce": input.coordinatorNonce,
            "coordinator_session_id": input.coordinatorSessionId,
            "coordinator_timestamp": input.coordinatorTimestamp,
            "domain": ProcessEvidenceProtocol.domain,
            "evidence_expires_at": input.evidenceExpiresAt,
            "metallib_hash": input.metallibHash,
            "process_public_key": input.processPublicKey,
            "provider_backend": input.providerBackend,
            "provider_platform": input.providerPlatform,
            "provider_version": input.providerVersion,
            "runtime_hash": input.runtimeHash,
            "se_public_key": input.sePublicKey,
            "serial_number": input.serialNumber,
            "version": ProcessEvidenceProtocol.version,
        ]
        if let value = input.sipEnabled { object["sip_enabled"] = value }
        if let value = input.secureBootEnabled { object["secure_boot_enabled"] = value }
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }
}

public struct ProcessEvidenceResponseContext: Sendable, Equatable {
    public let version: String
    public let coordinatorSessionId: String
    public let challengeGeneration: String
    public let challengeExpiresAt: String
    public let providerVersion: String
    public let providerPlatform: String
    public let providerBackend: String
    public let metallibHash: String

    public init(
        version: String,
        coordinatorSessionId: String,
        challengeGeneration: String,
        challengeExpiresAt: String,
        providerVersion: String,
        providerPlatform: String,
        providerBackend: String,
        metallibHash: String
    ) {
        self.version = version
        self.coordinatorSessionId = coordinatorSessionId
        self.challengeGeneration = challengeGeneration
        self.challengeExpiresAt = challengeExpiresAt
        self.providerVersion = providerVersion
        self.providerPlatform = providerPlatform
        self.providerBackend = providerBackend
        self.metallibHash = metallibHash
    }
}
