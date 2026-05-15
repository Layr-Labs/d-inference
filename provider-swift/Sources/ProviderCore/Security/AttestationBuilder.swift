/// AttestationBuilder -- constructs signed attestation blobs for coordinator verification.
///
/// Builds a JSON blob containing the provider's hardware identity, security
/// posture, and public keys, then signs it with the Secure Enclave P-256 key.
/// The coordinator verifies the signature to confirm the attestation came from
/// a genuine Secure Enclave on the claimed hardware.
///
/// The blob is JSON-encoded with sorted keys (matching Go's encoding/json
/// map key ordering) so that both sides produce identical bytes for signature
/// verification.
///
/// Ported from `enclave/Sources/DarkbloomEnclave/Attestation.swift`.

import CryptoKit
import Foundation
import os

private let logger = Logger(subsystem: "dev.darkbloom.provider", category: "attestation")

// MARK: - Data Types

/// An attestation blob containing hardware and software security state.
///
/// Fields are in alphabetical order by JSON key name. This ordering is critical
/// because the Go coordinator must produce identical JSON for signature verification.
/// Using JSONEncoder with .sortedKeys ensures deterministic output.
public struct AttestationBlob: Codable, Sendable {
    public let authenticatedRootEnabled: Bool
    public let binaryHash: String?
    public let chipName: String
    public let encryptionPublicKey: String?
    public let hardwareModel: String
    public let osVersion: String
    public let publicKey: String
    public let rdmaDisabled: Bool
    public let secureBootEnabled: Bool
    public let secureEnclaveAvailable: Bool
    public let serialNumber: String?
    public let sipEnabled: Bool
    public let systemVolumeHash: String?
    public let timestamp: Date

    enum CodingKeys: String, CodingKey {
        case authenticatedRootEnabled
        case binaryHash
        case chipName
        case encryptionPublicKey
        case hardwareModel
        case osVersion
        case publicKey
        case rdmaDisabled
        case secureBootEnabled
        case secureEnclaveAvailable
        case serialNumber
        case sipEnabled
        case systemVolumeHash
        case timestamp
    }
}

/// A signed attestation: the blob plus a DER-encoded P-256 ECDSA signature,
/// both base64-encoded.
///
/// The signature covers the JSON-encoded attestation blob (with sorted keys).
/// The coordinator verifies this signature using the public key embedded in
/// the attestation blob itself.
public struct SignedAttestation: Codable, Sendable {
    public let attestation: AttestationBlob
    public let signature: String  // base64 DER-encoded ECDSA signature
}

/// Fields covered by `status_signature` in an attestation challenge response.
public struct StatusCanonicalInput: Sendable, Equatable {
    public var nonce: String
    public var timestamp: String
    public var hypervisorActive: Bool?
    public var rdmaDisabled: Bool?
    public var sipEnabled: Bool?
    public var secureBootEnabled: Bool?
    public var binaryHash: String?
    public var activeModelHash: String?
    public var pythonHash: String?
    public var runtimeHash: String?
    public var templateHashes: [String: String]
    public var modelHashes: [String: String]

    public init(
        nonce: String,
        timestamp: String,
        hypervisorActive: Bool? = nil,
        rdmaDisabled: Bool? = nil,
        sipEnabled: Bool? = nil,
        secureBootEnabled: Bool? = nil,
        binaryHash: String? = nil,
        activeModelHash: String? = nil,
        pythonHash: String? = nil,
        runtimeHash: String? = nil,
        templateHashes: [String: String] = [:],
        modelHashes: [String: String] = [:]
    ) {
        self.nonce = nonce
        self.timestamp = timestamp
        self.hypervisorActive = hypervisorActive
        self.rdmaDisabled = rdmaDisabled
        self.sipEnabled = sipEnabled
        self.secureBootEnabled = secureBootEnabled
        self.binaryHash = binaryHash
        self.activeModelHash = activeModelHash
        self.pythonHash = pythonHash
        self.runtimeHash = runtimeHash
        self.templateHashes = templateHashes
        self.modelHashes = modelHashes
    }
}

public enum StatusCanonical {
    public static func build(_ input: StatusCanonicalInput) throws -> Data {
        var object: [String: Any] = [
            "nonce": input.nonce,
            "timestamp": input.timestamp,
        ]
        if let value = input.hypervisorActive { object["hypervisor_active"] = value }
        if let value = input.rdmaDisabled { object["rdma_disabled"] = value }
        if let value = input.sipEnabled { object["sip_enabled"] = value }
        if let value = input.secureBootEnabled { object["secure_boot_enabled"] = value }
        if let value = nonEmpty(input.binaryHash) { object["binary_hash"] = value }
        if let value = nonEmpty(input.activeModelHash) { object["active_model_hash"] = value }
        if let value = nonEmpty(input.pythonHash) { object["python_hash"] = value }
        if let value = nonEmpty(input.runtimeHash) { object["runtime_hash"] = value }
        if !input.templateHashes.isEmpty { object["template_hashes"] = input.templateHashes }
        if !input.modelHashes.isEmpty { object["model_hashes"] = input.modelHashes }

        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

// MARK: - Builder

/// Builds and signs attestation blobs using a Secure Enclave signing key.
///
/// Accepts any `AttestationSigner` -- either the ephemeral
/// `SecureEnclaveIdentity` (CryptoKit) or the persistent
/// `PersistentEnclaveKey` (Security framework, keychain-backed).
///
/// Usage:
///   1. Create or load a signing key (ephemeral or persistent)
///   2. Create an AttestationBuilder with that signer
///   3. Call `buildAttestation()` to get a SignedAttestation
///   4. Serialize to JSON and include in the Register message
public final class AttestationBuilder: @unchecked Sendable {
    private let identity: any AttestationSigner

    public init(identity: any AttestationSigner) {
        self.identity = identity
    }

    /// Build an attestation blob from the current system state and sign it.
    ///
    /// The blob is JSON-encoded with .sortedKeys for deterministic output,
    /// then signed with the Secure Enclave P-256 key. The coordinator
    /// reproduces the same JSON encoding to verify the signature.
    ///
    /// - Parameters:
    ///   - encryptionPublicKey: Optional base64-encoded X25519 public key to bind
    ///     to this attestation.
    ///   - binaryHash: Optional SHA-256 hex hash of the provider binary. The
    ///     coordinator verifies this matches the expected blessed version.
    public func buildAttestation(
        encryptionPublicKey: String? = nil,
        binaryHash: String? = nil
    ) throws -> SignedAttestation {
        let blob = AttestationBlob(
            authenticatedRootEnabled: checkAuthenticatedRootEnabled(),
            binaryHash: binaryHash,
            chipName: detectChipName(),
            encryptionPublicKey: encryptionPublicKey,
            hardwareModel: detectHardwareModel(),
            osVersion: detectOSVersion(),
            publicKey: identity.publicKeyBase64,
            rdmaDisabled: checkRDMADisabled(),
            secureBootEnabled: checkSecureBootEnabled(),
            secureEnclaveAvailable: SecureEnclave.isAvailable,
            serialNumber: detectSerialNumber(),
            sipEnabled: checkSIPEnabled(),
            systemVolumeHash: systemVolumeHash(),
            timestamp: Date()
        )

        // Encode with sorted keys for deterministic JSON (must match Go's encoding)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        let blobData = try encoder.encode(blob)

        // Sign the JSON bytes with the Secure Enclave key
        let signature = try identity.sign(blobData)

        logger.info("Built signed attestation blob (\(blobData.count) bytes)")
        return SignedAttestation(
            attestation: blob,
            signature: signature.base64EncodedString()
        )
    }

    /// Build the attestation and return it as raw JSON bytes.
    ///
    /// Returns the signed attestation as deterministic JSON (sorted keys),
    /// suitable for embedding in a WebSocket Register message. The raw bytes
    /// preserve the exact encoding needed for signature verification.
    public func buildAttestationJSON(
        encryptionPublicKey: String? = nil,
        binaryHash: String? = nil
    ) throws -> Data {
        let signed = try buildAttestation(
            encryptionPublicKey: encryptionPublicKey,
            binaryHash: binaryHash
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(signed)
    }

    /// Verify a signed attestation's signature against the embedded public key.
    ///
    /// This re-encodes the attestation blob with the same encoder settings
    /// (.sortedKeys, .iso8601) and verifies the P-256 ECDSA signature.
    /// Used for local verification; the coordinator has its own Go
    /// implementation of this verification.
    public static func verify(_ signed: SignedAttestation) -> Bool {
        guard let pubKeyData = Data(base64Encoded: signed.attestation.publicKey),
              let sigData = Data(base64Encoded: signed.signature)
        else {
            return false
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        guard let blobData = try? encoder.encode(signed.attestation) else {
            return false
        }

        return SecureEnclaveIdentity.verify(
            signature: sigData,
            for: blobData,
            publicKey: pubKeyData
        )
    }
}

// MARK: - Challenge-Response

extension AttestationBuilder {

    /// Sign an attestation challenge from the coordinator.
    ///
    /// The coordinator sends periodic `attestation_challenge` messages with
    /// a random nonce and timestamp. The provider signs `nonce + timestamp`
    /// with its Secure Enclave key to prove the same hardware is still running.
    ///
    /// Returns a base64-encoded DER ECDSA signature of the nonce bytes.
    public func signChallenge(nonce: String, timestamp: String) throws -> String {
        let sigData = try identity.sign(Data((nonce + timestamp).utf8))
        return sigData.base64EncodedString()
    }

    /// Build a full attestation response for a coordinator challenge.
    ///
    /// Includes the signed nonce, current security state, and optionally
    /// a signed status string for the coordinator to verify provider state.
    public func buildChallengeResponse(
        nonce: String,
        timestamp: String,
        providerPublicKey: String,
        binaryHash: String? = nil,
        activeModelHash: String? = nil,
        runtimeHashes: RuntimeHashes? = nil,
        hypervisorActive: Bool? = nil,
        modelHashes: [String: String] = [:]
    ) throws -> ProviderMessage.AttestationResponse {
        let signature = try signChallenge(nonce: nonce, timestamp: timestamp)

        let rdmaDisabled = checkRDMADisabled()
        let sipEnabled = checkSIPEnabled()
        let secureBootEnabled = checkSecureBootEnabled()
        let statusData = try StatusCanonical.build(StatusCanonicalInput(
            nonce: nonce,
            timestamp: timestamp,
            hypervisorActive: hypervisorActive,
            rdmaDisabled: rdmaDisabled,
            sipEnabled: sipEnabled,
            secureBootEnabled: secureBootEnabled,
            binaryHash: binaryHash,
            activeModelHash: activeModelHash,
            pythonHash: runtimeHashes?.pythonHash,
            runtimeHash: runtimeHashes?.runtimeHash,
            templateHashes: runtimeHashes?.templateHashes ?? [:],
            modelHashes: modelHashes
        ))
        let statusSignature = try identity.sign(statusData).base64EncodedString()

        return ProviderMessage.AttestationResponse(
            nonce: nonce,
            signature: signature,
            statusSignature: statusSignature,
            publicKey: providerPublicKey,
            hypervisorActive: hypervisorActive,
            rdmaDisabled: rdmaDisabled,
            sipEnabled: sipEnabled,
            secureBootEnabled: secureBootEnabled,
            binaryHash: binaryHash,
            activeModelHash: activeModelHash,
            pythonHash: runtimeHashes?.pythonHash,
            runtimeHash: runtimeHashes?.runtimeHash,
            templateHashes: runtimeHashes?.templateHashes ?? [:],
            modelHashes: modelHashes
        )
    }
}

// MARK: - System Info Helpers

/// Get the machine model identifier (e.g., "Mac16,1") via sysctl.
private func detectHardwareModel() -> String {
    var size: Int = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    guard size > 0 else { return "Unknown" }
    var model = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &model, &size, nil, 0)
    return String(cString: model)
}

/// Get the chip name (e.g., "Apple M4 Max") from system_profiler.
///
/// Parses the "Chip:" line from SPHardwareDataType output. Returns "Unknown"
/// if the chip name cannot be determined.
private func detectChipName() -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
    process.arguments = ["SPHardwareDataType"]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    guard let _ = try? process.run() else { return "Unknown" }
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""

    for line in output.components(separatedBy: "\n") {
        if line.contains("Chip:") {
            return line.components(separatedBy: ":").last?
                .trimmingCharacters(in: .whitespaces) ?? "Unknown"
        }
    }
    return "Unknown"
}

/// Get the OS version string (e.g., "15.3.0").
private func detectOSVersion() -> String {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
}

/// Get the hardware serial number for MDM cross-reference.
///
/// The coordinator uses this to look up the device in MicroMDM and
/// independently verify its security posture via MDM SecurityInfo.
private func detectSerialNumber() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
    process.arguments = ["SPHardwareDataType"]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    guard let _ = try? process.run() else { return nil }
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""

    for line in output.components(separatedBy: "\n") {
        if line.contains("Serial Number") {
            return line.components(separatedBy: ":").last?
                .trimmingCharacters(in: .whitespaces)
        }
    }
    return nil
}
