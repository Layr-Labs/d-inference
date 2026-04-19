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
    public let authenticatedRootEnabled: Bool   // Authenticated Root Volume (sealed system volume)
    public let binaryHash: String?             // SHA-256 of the provider binary, for integrity verification
    public let chipName: String                // e.g. "Apple M3 Max"
    public let encryptionPublicKey: String?    // base64 X25519 public key, bound to this identity
    public let hardwareModel: String           // e.g. "Mac15,8"
    public let osVersion: String               // e.g. "15.3.0"
    public let publicKey: String               // base64 raw P-256 public key (64 bytes: X||Y)
    public let rdmaDisabled: Bool              // RDMA must be disabled — if enabled, remote memory access bypasses all protections
    public let secureBootEnabled: Bool
    public let secureEnclaveAvailable: Bool
    public let serialNumber: String?           // Hardware serial number for MDM cross-reference
    public let sipEnabled: Bool
    public let systemVolumeHash: String?       // ARV snapshot hash (proves unmodified system volume)
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
    /// - Parameters:
    ///   - encryptionPublicKey: Optional base64-encoded X25519 public key to bind
    ///     to this attestation.
    ///   - binaryHash: Optional SHA-256 hex hash of the provider binary. The
    ///     coordinator verifies this matches the expected blessed version, preventing
    ///     providers from running modified binaries.
    public func createAttestation(encryptionPublicKey: String? = nil, binaryHash: String? = nil) throws -> SignedAttestation {
        let blob = AttestationBlob(
            authenticatedRootEnabled: checkAuthenticatedRootEnabled(),
            binaryHash: binaryHash,
            chipName: getChipName(),
            encryptionPublicKey: encryptionPublicKey,
            hardwareModel: getHardwareModel(),
            osVersion: getOSVersion(),
            publicKey: identity.publicKeyBase64,
            rdmaDisabled: checkRDMADisabled(),
            secureBootEnabled: checkSecureBootEnabled(),
            secureEnclaveAvailable: SecureEnclave.isAvailable,
            serialNumber: getSerialNumber(),
            sipEnabled: checkSIPEnabled(),
            systemVolumeHash: getSystemVolumeHash(),
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

/// Get the hardware serial number for MDM cross-reference.
///
/// The coordinator uses this to look up the device in MicroMDM and
/// independently verify its security posture via MDM SecurityInfo.
func getSerialNumber() -> String? {
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
        if line.contains("Serial Number") {
            return line.components(separatedBy: ":").last?
                .trimmingCharacters(in: .whitespaces)
        }
    }
    return nil
}

/// Check if RDMA (Remote Direct Memory Access) is disabled.
///
/// RDMA over Thunderbolt 5 allows another Mac to directly read this
/// process's memory, bypassing PT_DENY_ATTACH, Hardened Runtime, and SIP.
/// RDMA is disabled by default; enabling requires Recovery OS access.
/// Returns true if RDMA is disabled (safe) or rdma_ctl is not available.
func checkRDMADisabled() -> Bool {
    let pipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/rdma_ctl")
    process.arguments = ["status"]
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
    } catch {
        // rdma_ctl not available — RDMA not supported on this Mac
        return true
    }
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    return output.trimmingCharacters(in: .whitespacesAndNewlines) == "disabled"
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
/// On Apple Silicon, Full Security is the default. Reduced Security or
/// Permissive Security must be opted into via 1TR (Recovery Mode) and
/// downgrading to either still leaves the bit auditable via `bputil`.
/// We invoke `bputil -d` (reads boot policy without prompting) and look
/// for "Full Security" in the output. Anything other than Full Security
/// means the user reduced their boot security posture, so we return false
/// and the coordinator drops trust.
///
/// In production the coordinator additionally cross-checks against MDA's
/// SecureBoot OID (1.2.840.113635.100.8.13.2) so a compromised local
/// `bputil` binary cannot lie — that check is on the coordinator side
/// (see verifyAppleDeviceAttestation in coordinator/internal/api/provider.go).
func checkSecureBootEnabled() -> Bool {
    let pipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/bputil")
    process.arguments = ["-d"]
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
    } catch {
        // bputil missing or unrunnable: this is unexpected on Apple
        // Silicon. Fail closed so the coordinator can decide.
        return false
    }
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    // bputil -d prints "Boot Policy: Full Security" or
    // "Local Policy: Full Security" depending on the macOS version.
    return output.contains("Full Security")
}

/// Check if Authenticated Root Volume (ARV) is enabled.
///
/// ARV seals the system volume with a cryptographic hash. Any modification
/// to system files breaks the seal and the volume won't mount.
///
/// Detection: checks `diskutil info /` for "Sealed: Yes" which works
/// reliably on all macOS configurations including multi-boot EC2 Macs
/// where `csrutil authenticated-root status` prompts interactively.
func checkAuthenticatedRootEnabled() -> Bool {
    let pipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    process.arguments = ["info", "/"]
    process.standardOutput = pipe
    process.standardError = Pipe()
    try? process.run()
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""

    for line in output.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("Sealed:") {
            return trimmed.contains("Yes")
        }
    }
    return false
}

/// Get the Authenticated Root Volume snapshot hash.
///
/// This is the cryptographic hash of the sealed system volume. It proves
/// the system volume is Apple's original, unmodified volume. The hash
/// is embedded in the APFS snapshot name.
func getSystemVolumeHash() -> String? {
    let pipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    process.arguments = ["info", "/"]
    process.standardOutput = pipe
    process.standardError = Pipe()
    try? process.run()
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""

    // Extract hash from snapshot name: com.apple.os.update-<HASH>
    for line in output.components(separatedBy: "\n") {
        if line.contains("APFS Snapshot Name") {
            if let range = line.range(of: "com.apple.os.update-") {
                let hash = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !hash.isEmpty {
                    return hash
                }
            }
        }
    }
    return nil
}
