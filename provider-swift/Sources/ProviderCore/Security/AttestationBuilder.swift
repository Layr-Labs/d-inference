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
    /// Structured hardware family and live runtime identity are signed here,
    /// not inferred from unsigned Register siblings at the coordinator.
    public let chipFamily: String?
    public let chipName: String
    public let encryptionPublicKey: String?
    public let hardwareModel: String
    public let metallibHash: String?
    public let osVersion: String
    public let publicKey: String
    public let rdmaDisabled: Bool
    public let runtimeCapabilities: [ProviderRuntimeCapability]?
    public let secureBootEnabled: Bool
    public let secureEnclaveAvailable: Bool
    public let serialNumber: String?
    public let sipEnabled: Bool
    public let systemVolumeHash: String?
    public let timestamp: Date

    enum CodingKeys: String, CodingKey {
        case authenticatedRootEnabled
        case binaryHash
        case chipFamily
        case chipName
        case encryptionPublicKey
        case hardwareModel
        case metallibHash
        case osVersion
        case publicKey
        case rdmaDisabled
        case runtimeCapabilities
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
    private let runner: SecurityCommandRunner
    private let factsLock = NSLock()
    private var cachedFacts: StaticAttestationFacts?

    /// - Parameter runner: the command runner behind every posture probe
    ///   (`csrutil`, `rdma_ctl`, `diskutil`, `system_profiler`, `ioreg`) —
    ///   injectable so tests can count spawns exactly; `.live` in production.
    public init(identity: any AttestationSigner, runner: SecurityCommandRunner = .live) {
        self.identity = identity
        self.runner = runner
    }

    /// The boot-immutable posture facts, gathered ONCE per process on first
    /// use and reused by every registration attestation and challenge
    /// response after that. Every field can only change across a reboot
    /// (SIP / authenticated-root / RDMA flip in Recovery; the sealed system
    /// volume, serial, chip and model never) — and a reboot restarts the
    /// daemon, so a process-lifetime cache is exactly as fresh as a per-call
    /// probe. Per-call probing cost ≈0.4–0.56 s of `Process.run()` +
    /// `waitUntilExit` on every (re)connect (including a duplicate
    /// `csrutil authenticated-root` spawn) and ≈0.1 s inline on the serial
    /// event loop for every 5-minute challenge. Only timestamp, encryption
    /// key and signature must be fresh, and they still are.
    ///
    /// Only a DEFINITIVE gather is cached. Every probe maps its own failure
    /// to the negative posture (a `csrutil` spawn refused under load reads
    /// as sip=false / authenticated-root=false), and the coordinator
    /// hard-untrusts on those fields; pinning one such reading for the
    /// process would leave the provider unroutable until a daemon restart.
    /// A non-definitive gather is reported once — exactly what a failed
    /// probe cost before the cache — and the next registration or
    /// challenge probes again and heals.
    public func staticFacts() -> StaticAttestationFacts {
        factsLock.lock()
        defer { factsLock.unlock() }
        if let cachedFacts { return cachedFacts }
        // Gathered under the lock: a concurrent first caller waits rather
        // than spawning the probes a second time.
        let gathered = StaticAttestationFacts.gather(runner: runner)
        if gathered.definitive {
            cachedFacts = gathered.facts
        } else {
            logger.warning(
                "attestation posture probe did not complete (transient tool failure) — reporting it uncached; the next challenge re-probes")
        }
        return gathered.facts
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
        binaryHash: String? = nil,
        chipFamily: ChipFamily? = nil,
        runtimeCapabilities: Set<ProviderRuntimeCapability> = [],
        metallibHash: String? = nil
    ) throws -> SignedAttestation {
        let facts = staticFacts()
        let blob = AttestationBlob(
            authenticatedRootEnabled: facts.authenticatedRootEnabled,
            binaryHash: binaryHash,
            chipFamily: chipFamily?.rawValue,
            chipName: facts.chipName,
            encryptionPublicKey: encryptionPublicKey,
            hardwareModel: facts.hardwareModel,
            metallibHash: metallibHash,
            osVersion: facts.osVersion,
            publicKey: identity.publicKeyBase64,
            rdmaDisabled: facts.rdmaDisabled,
            runtimeCapabilities: runtimeCapabilities.isEmpty
                ? nil
                : runtimeCapabilities.sorted(),
            secureBootEnabled: facts.secureBootEnabled,
            secureEnclaveAvailable: facts.secureEnclaveAvailable,
            serialNumber: facts.serialNumber,
            sipEnabled: facts.sipEnabled,
            systemVolumeHash: facts.systemVolumeHash,
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
        binaryHash: String? = nil,
        chipFamily: ChipFamily? = nil,
        runtimeCapabilities: Set<ProviderRuntimeCapability> = [],
        metallibHash: String? = nil
    ) throws -> Data {
        let signed = try buildAttestation(
            encryptionPublicKey: encryptionPublicKey,
            binaryHash: binaryHash,
            chipFamily: chipFamily,
            runtimeCapabilities: runtimeCapabilities,
            metallibHash: metallibHash
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
        modelHashes: [String: String] = [:]
    ) throws -> ProviderMessage.AttestationResponse {
        let signature = try signChallenge(nonce: nonce, timestamp: timestamp)

        // Boot-immutable posture from the process-lifetime cache: zero
        // spawns per challenge after the first (was rdma_ctl + csrutil
        // status + csrutil authenticated-root, ≈0.1 s, every 5 minutes and
        // immediately after every register).
        let facts = staticFacts()
        let rdmaDisabled = facts.rdmaDisabled
        let sipEnabled = facts.sipEnabled
        let secureBootEnabled = facts.secureBootEnabled
        let statusData = try StatusCanonical.build(StatusCanonicalInput(
            nonce: nonce,
            timestamp: timestamp,
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

// MARK: - Static facts

/// Boot-immutable posture and hardware identity, gathered once per process
/// (see `AttestationBuilder.staticFacts`).
public struct StaticAttestationFacts: Sendable, Equatable {
    public let authenticatedRootEnabled: Bool
    public let chipName: String
    public let hardwareModel: String
    public let osVersion: String
    public let rdmaDisabled: Bool
    public let serialNumber: String?
    public let sipEnabled: Bool
    public let systemVolumeHash: String?
    public let secureEnclaveAvailable: Bool

    /// Historical Authenticated Root proxy retained for wire compatibility
    /// (`checkSecureBootEnabled` IS `checkAuthenticatedRootEnabled`): one
    /// `csrutil authenticated-root` probe feeds both fields instead of the
    /// former two spawns per attestation.
    public var secureBootEnabled: Bool { authenticatedRootEnabled }

    public init(
        authenticatedRootEnabled: Bool,
        chipName: String,
        hardwareModel: String,
        osVersion: String,
        rdmaDisabled: Bool,
        serialNumber: String?,
        sipEnabled: Bool,
        systemVolumeHash: String?,
        secureEnclaveAvailable: Bool
    ) {
        self.authenticatedRootEnabled = authenticatedRootEnabled
        self.chipName = chipName
        self.hardwareModel = hardwareModel
        self.osVersion = osVersion
        self.rdmaDisabled = rdmaDisabled
        self.serialNumber = serialNumber
        self.sipEnabled = sipEnabled
        self.systemVolumeHash = systemVolumeHash
        self.secureEnclaveAvailable = secureEnclaveAvailable
    }

    /// Probe every fact once through `runner`.
    ///
    /// `definitive` is false when any probe failed in a way that says
    /// nothing about the box: an installed tool whose spawn threw
    /// (`posix_spawn` EAGAIN/ENOMEM, `Pipe()` EMFILE under load), a
    /// non-zero exit, or `csrutil status` output that parsed to no known
    /// state. Each of those reads as the NEGATIVE posture (sip=false,
    /// authenticated-root=false, rdma unknown), which is the pre-cache
    /// behaviour for one report but must not be cached for the process
    /// (`AttestationBuilder.staticFacts`). A tool that is not installed at
    /// all (`rdma_ctl` before macOS 26.2) is a boot-immutable fact and
    /// keeps the gather definitive.
    static func gather(runner: SecurityCommandRunner) -> (facts: StaticAttestationFacts, definitive: Bool) {
        let outcomes = ProbeOutcomes()
        let recording = SecurityCommandRunner { path, arguments in
            do {
                let result = try runner.run(path, arguments)
                if result.terminationStatus != 0 { outcomes.markTransientFailure() }
                return result
            } catch {
                if FileManager.default.fileExists(atPath: path) { outcomes.markTransientFailure() }
                throw error
            }
        }
        let sipStatus = sipStatusPosture(runner: recording)
        let facts = StaticAttestationFacts(
            authenticatedRootEnabled: checkAuthenticatedRootEnabled(runner: recording),
            chipName: detectChipName(runner: recording),
            hardwareModel: detectHardwareModel(),
            osVersion: detectOSVersion(),
            rdmaDisabled: checkRDMADisabled(runner: recording),
            serialNumber: detectSerialNumber(runner: recording),
            sipEnabled: sipStatus.reportsEnabled,
            // Via a file-scope helper: the struct's own `systemVolumeHash`
            // member shadows the free function inside this scope.
            systemVolumeHash: probeSystemVolumeHash(runner: recording),
            secureEnclaveAvailable: SecureEnclave.isAvailable)
        return (facts, !outcomes.sawTransientFailure && sipStatus.isDefinitive)
    }
}

/// Records whether any probe of one `gather` failed transiently.
private final class ProbeOutcomes: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false
    func markTransientFailure() { lock.withLock { failed = true } }
    var sawTransientFailure: Bool { lock.withLock { failed } }
}

/// File-scope forwarder so `StaticAttestationFacts.gather` can reach the
/// free function its own `systemVolumeHash` member would otherwise shadow.
private func probeSystemVolumeHash(runner: SecurityCommandRunner) -> String? {
    systemVolumeHash(runner: runner)
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
private func detectChipName(runner: SecurityCommandRunner = .live) -> String {
    guard let result = try? runner.run("/usr/sbin/system_profiler", ["SPHardwareDataType"]) else {
        return "Unknown"
    }
    let output = result.stdout

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
private func detectSerialNumber(runner: SecurityCommandRunner = .live) -> String? {
    if let serial = detectSerialNumberFromIOReg(runner: runner) {
        return serial
    }
    return detectSerialNumberFromSystemProfiler(runner: runner)
}

private func detectSerialNumberFromIOReg(runner: SecurityCommandRunner) -> String? {
    guard let result = try? runner.run("/usr/sbin/ioreg", ["-c", "IOPlatformExpertDevice", "-d", "2"])
    else { return nil }
    return parseSerialNumberFromIOReg(result.stdout)
}

private func detectSerialNumberFromSystemProfiler(runner: SecurityCommandRunner) -> String? {
    guard let result = try? runner.run("/usr/sbin/system_profiler", ["SPHardwareDataType"])
    else { return nil }
    return parseSerialNumberFromSystemProfiler(result.stdout)
}

func parseSerialNumberFromIOReg(_ output: String) -> String? {
    for line in output.components(separatedBy: "\n") {
        guard line.contains("IOPlatformSerialNumber") else { continue }
        let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
        if parts.count >= 4 {
            let candidate = String(parts[3]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty {
                return candidate
            }
        }
    }
    return nil
}

func parseSerialNumberFromSystemProfiler(_ output: String) -> String? {
    for line in output.components(separatedBy: "\n") {
        if line.contains("Serial Number") {
            return line.components(separatedBy: ":").last?
                .trimmingCharacters(in: .whitespaces)
        }
    }
    return nil
}
