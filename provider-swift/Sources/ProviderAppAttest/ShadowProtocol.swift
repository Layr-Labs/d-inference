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
    public var protocolVersion: Int?
    public var accountScope: String?
    public var enrollmentSession: String?
    public var status: AppAttestStatus?
    public var action: String
    public var session: String
    public var environment: String?
    public var keyID: String?
    public var challenge: String?
    public var result: String?
    public var appleError: AppAttestAppleError?
    public var availabilityReason: AppAttestAvailabilityReason?
    public var appleErrorSource: AppAttestAppleErrorSource?
    public var proof: String?
    public var encryptedChallenge: ShadowEncryptedChallenge?
    /// Diagnostics on `ready` replies only. Never part of `clientHash`; the
    /// coordinator strips invalid values instead of rejecting the frame.
    public var launchSession: AppAttestLaunchSession?
    public var bootTime: Int64?
    /// Present only with result `busy`, 1...`AppleOperationStall.maxReportedSeconds`.
    public var operationStalledSeconds: Int?
    /// Further `ready`-only diagnostics (see AppAttestReadyDiagnostics.swift).
    public var processStartedAt: Int64?
    public var previousExit: AppAttestPreviousExit?
    public var startReason: AppAttestStartReason?
    public var consoleUserActive: Bool?
    public var sipEnabled: Bool?
    public var authenticatedRoot: Bool?
    public var preflight: AppAttestPreflight?
    public var keyHistory: AppAttestKeyHistory?
    public var pushHistory: AppAttestPushHistory?
    /// Failed attestation/assertion replies with result apple_error or
    /// apple_invalid_key only: the closed NSError chain, top level first.
    public var nativeErrorChain: [AppAttestNativeErrorEntry]?

    public init(action: String, session: String) { self.action = action; self.session = session }
    enum CodingKeys: String, CodingKey {
        case action, session, environment, challenge, result, proof
        case protocolVersion = "protocol_version"
        case accountScope = "account_scope"
        case enrollmentSession = "enrollment_session"
        case status
        case keyID = "key_id"
        case encryptedChallenge = "encrypted_challenge"
        case appleError = "apple_error"
        case availabilityReason = "availability_reason"
        case appleErrorSource = "apple_error_source"
        case launchSession = "launch_session"
        case bootTime = "boot_time"
        case operationStalledSeconds = "operation_stalled_seconds"
        case processStartedAt = "process_started_at"
        case previousExit = "previous_exit"
        case startReason = "start_reason"
        case consoleUserActive = "console_user_active"
        case sipEnabled = "sip_enabled"
        case authenticatedRoot = "authenticated_root"
        case preflight
        case keyHistory = "key_history"
        case pushHistory = "push_history"
        case nativeErrorChain = "native_error_chain"
    }

    public func clientHash(publicKey: String) -> Data {
        var data = Data()
        var values = [protocolVersion == 3 ? "darkbloom.app-attest.shadow.v3" : (protocolVersion == 2 ? "darkbloom.app-attest.shadow.v2" : "darkbloom.app-attest.shadow.v1"), action, session, environment ?? "", keyID ?? "", challenge ?? "", publicKey]
        if [2,3].contains(protocolVersion ?? 0) { values += [accountScope ?? ""] + (status?.values ?? ["", "", "", "", ""]) }
        if protocolVersion == 3 { values += (status?.hardwareValues ?? Array(repeating: "", count: 6)) + [status?.attestationPublicKey ?? ""] }
        for value in values {
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
    case invalidRequest = "invalid_request", operationTimeout = "operation_timeout"
}

public protocol AppAttestService: Sendable {
    func checkAvailability(environment: String) async throws
    func generateKey() async throws -> String
    func attestKey(_ id: String, hash: Data) async throws -> Data
    func generateAssertion(_ id: String, hash: Data) async throws -> Data
    /// When the outstanding uncancellable Apple call was admitted, or nil.
    /// No default: a silent nil would hide a stalled gate.
    func operationHeldSince() async -> Date?
}

public struct ShadowKeyRecord: Codable, Sendable {
    public var keyID: String
    public var attested: Bool
    public var createdAt: Date
    public var pendingProof: String?
    public var pendingEnrollment: String?
    public var pendingStatus: AppAttestStatus?
    public var pendingCreatedAt: Date?
    public var generationCount: Int?
    /// Only a failed generateKey call with no returned identifier may shorten
    /// the pre-key cooldown. An issued/retired key never sets this field.
    public var generationRetryAfter: Date?
    public var retryEnrollment: ShadowEnrollmentAttempt?
    /// Persisted before the one-time Apple enrollment call. A process exit or
    /// late callback cannot make an uncertain key look safe to attest again.
    public var attestationStartedAt: Date?
    // Diagnostics only (`key_history`); nil in records written by older
    // providers. None of these gates enrollment, rotation or cooldowns.
    /// `kern.boottime` when the key's pre-generation marker was written.
    public var createdBootTime: Int64?
    /// Provider version that generated the key.
    public var createdAppVersion: String?
    /// Last successful attestKey/generateAssertion with this key.
    public var lastSuccessAt: Date?
    /// Apple-call assertion failures with this key since its last success.
    public var consecutiveAssertionFailures: Int?
    /// Budget record only: the last `KeyGenerationHistory.cap` generation
    /// attempts across account scopes.
    public var generationHistory: [Date]?
}

public protocol ShadowKeyStorage: Sendable {
    func load(scope: String) throws -> ShadowKeyRecord?
    func save(_ record: ShadowKeyRecord, scope: String) throws
}

/// Locally derived, assertion-bound measurements. Apple does not independently
/// certify these values; the coordinator preserves their source.
public struct AppAttestStatus: Codable, Sendable, Equatable {
    public var attestationPublicKey: String?
    public var machineModel: String?
    public var memoryGB: String?
    public var cpuTotal: String?
    public var cpuPerformance: String?
    public var cpuEfficiency: String?
    public var gpuCores: String?

    public var osVersion: String
    public var osBuild: String
    public var appVersion: String
    public var chip: String
    public var binaryHash: String
    public init(osVersion: String, osBuild: String, appVersion: String, chip: String, binaryHash: String, machineModel: String? = nil, memoryGB: String? = nil, cpuTotal: String? = nil, cpuPerformance: String? = nil, cpuEfficiency: String? = nil, gpuCores: String? = nil, attestationPublicKey: String? = nil) {
        self.attestationPublicKey=attestationPublicKey
        self.machineModel=machineModel; self.memoryGB=memoryGB; self.cpuTotal=cpuTotal; self.cpuPerformance=cpuPerformance; self.cpuEfficiency=cpuEfficiency; self.gpuCores=gpuCores
        self.osVersion=osVersion; self.osBuild=osBuild; self.appVersion=appVersion; self.chip=chip; self.binaryHash=binaryHash
    }
    enum CodingKeys: String, CodingKey {
        case attestationPublicKey="attestation_public_key"
        case machineModel="machine_model", memoryGB="memory_gb", cpuTotal="cpu_total", cpuPerformance="cpu_performance", cpuEfficiency="cpu_efficiency", gpuCores="gpu_cores"
        case osVersion="os_version", osBuild="os_build", appVersion="app_version", chip, binaryHash="binary_hash"
    }
    var values: [String] { [osVersion,osBuild,appVersion,chip,binaryHash] }
    var hardwareValues: [String] { [machineModel ?? "", memoryGB ?? "", cpuTotal ?? "", cpuPerformance ?? "", cpuEfficiency ?? "", gpuCores ?? ""] }
}
