/// Attestation — hardware and software security state attestation.
///
/// This module builds signed attestation blobs that prove a provider's
/// hardware identity and security configuration. The attestation blob
/// contains:
///   - Hardware identity: chip name (e.g., "Apple M4 Max"), machine model
///   - Security state: Secure Enclave availability, SIP status, Secure Boot
///   - Public keys: P-256 signing key (from SE), optional X25519 encryption key
///   - Timestamp: ISO 8601 for freshness checking
///
/// The blob is JSON-encoded with sorted keys (matching Go's encoding/json
/// map key ordering) and signed with the Secure Enclave P-256 key. The
/// coordinator verifies the signature to confirm the attestation came from
/// a genuine Secure Enclave.
///
/// Security note on software checks:
///   The SIP and Secure Boot checks in this module are software-based
///   (calling `csrutil status` and making assumptions about Apple Silicon).
///   In production, these would come from Managed Device Attestation (MDA),
///   which provides hardware-attested evidence via Apple Business Manager.
///   The software checks are development placeholders that demonstrate the
///   attestation flow.
///
/// Key binding:
///   The optional `encryptionPublicKey` field binds the provider's X25519
///   encryption key to its Secure Enclave identity. This proves that the
///   same physical device controls both the signing key (for attestation)
///   and the encryption key (for future encrypted inference).

import CryptoKit
import Foundation

// MARK: - Data Types

/// An attestation blob containing hardware and software security state.
///
/// Fields are in alphabetical order by property name to match Swift's
/// JSONEncoder with .sortedKeys output. This ordering is critical because
/// the Go coordinator must produce identical JSON for signature verification.
///
/// In production, the security fields (SIP, Secure Boot) would come from
/// Managed Device Attestation (MDA) which provides hardware-attested
/// evidence. The software checks here are a development placeholder.
public struct AttestationBlob: Codable {
    public let chipName: String                // e.g. "Apple M3 Max"
    public let encryptionPublicKey: String?    // base64 X25519 public key, bound to this identity
    public let hardwareModel: String           // e.g. "Mac15,8"
    public let osVersion: String               // e.g. "15.3.0"
    public let publicKey: String               // base64 raw P-256 public key (64 bytes: X||Y)
    public let secureBootEnabled: Bool
    public let secureEnclaveAvailable: Bool
    public let sipEnabled: Bool
    public let timestamp: Date
}

/// A signed attestation: the blob plus a DER-encoded P-256 ECDSA
/// signature, both base64-encoded.
///
/// The signature covers the JSON-encoded attestation blob (with sorted keys).
/// The coordinator verifies this signature using the public key embedded
/// in the attestation blob itself.
public struct SignedAttestation: Codable {
    public let attestation: AttestationBlob
    public let signature: String               // base64 DER-encoded ECDSA signature
}

// MARK: - Service

/// Builds and signs attestation blobs using a Secure Enclave identity.
///
/// Usage:
///   1. Create a SecureEnclaveIdentity (generates or loads a key)
///   2. Create an AttestationService with that identity
///   3. Call createAttestation() to get a SignedAttestation
///   4. Serialize to JSON and include in the provider's Register message
public final class AttestationService {
    private let identity: SecureEnclaveIdentity

    public init(identity: SecureEnclaveIdentity) {
        self.identity = identity
    }

    /// Build an attestation blob from the current system state and sign it.
    ///
    /// The blob is JSON-encoded with .sortedKeys for deterministic output,
    /// then signed with the Secure Enclave P-256 key. The coordinator
    /// reproduces the same JSON encoding to verify the signature.
    ///
    /// - Parameter encryptionPublicKey: Optional base64-encoded X25519 public
    ///   key to bind to this attestation. When set, the coordinator verifies
    ///   that this key matches the public_key in the Register message, proving
    ///   the same device controls both keys.
    public func createAttestation(encryptionPublicKey: String? = nil) throws -> SignedAttestation {
        let blob = AttestationBlob(
            chipName: getChipName(),
            encryptionPublicKey: encryptionPublicKey,
            hardwareModel: getHardwareModel(),
            osVersion: getOSVersion(),
            publicKey: identity.publicKeyBase64,
            secureBootEnabled: checkSecureBootEnabled(),
            secureEnclaveAvailable: SecureEnclave.isAvailable,
            sipEnabled: checkSIPEnabled(),
            timestamp: Date()
        )

        // Encode with sorted keys for deterministic JSON (must match Go's encoding)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys   // deterministic for signing
        let blobData = try encoder.encode(blob)

        // Sign the JSON bytes with the Secure Enclave key
        let signature = try identity.sign(blobData)

        return SignedAttestation(
            attestation: blob,
            signature: signature.base64EncodedString()
        )
    }

    /// Verify a signed attestation's signature against the embedded public key.
    ///
    /// This re-encodes the attestation blob with the same encoder settings
    /// (.sortedKeys, .iso8601) and verifies the P-256 ECDSA signature.
    /// Used for local verification; the coordinator has its own Go
    /// implementation of this verification.
    public static func verify(_ signed: SignedAttestation) -> Bool {
        guard let pubKeyData = Data(base64Encoded: signed.attestation.publicKey),
              let sigData = Data(base64Encoded: signed.signature) else {
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

// MARK: - System Info Helpers

/// Get the machine model identifier (e.g., "Mac16,1") via sysctl.
func getHardwareModel() -> String {
    var size: Int = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var model = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &model, &size, nil, 0)
    return String(cString: model)
}

/// Get the chip name (e.g., "Apple M4 Max") from system_profiler.
///
/// Parses the "Chip:" line from SPHardwareDataType output. Returns "Unknown"
/// if the chip name cannot be determined.
func getChipName() -> String {
    let pipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
    process.arguments = ["SPHardwareDataType"]
    process.standardOutput = pipe
    process.standardError = Pipe()
    try? process.run()
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
func getOSVersion() -> String {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
}

/// Check if System Integrity Protection (SIP) is enabled.
///
/// Note: In production this would come from MDA (hardware-attested).
/// This software check (calling `csrutil status`) is a development
/// placeholder that can be spoofed by a compromised system.
func checkSIPEnabled() -> Bool {
    let pipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/csrutil")
    process.arguments = ["status"]
    process.standardOutput = pipe
    process.standardError = Pipe()
    try? process.run()
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    return output.contains("enabled")
}

/// Check if Secure Boot is enabled.
///
/// On Apple Silicon, Secure Boot is always enabled in Full Security mode.
/// In production this would come from MDA. This always returns true as
/// a development placeholder.
func checkSecureBootEnabled() -> Bool {
    return true
}
