import Foundation

// Closed, bounded diagnostics carried on `ready` replies (and the native error
// chain on failed attestation/assertion replies). None of these values enters
// `clientHash` or any authorization decision; the coordinator strips invalid
// members instead of rejecting the frame. No user names, paths, serials, key
// identifiers or native error descriptions are ever represented here.

/// Whether the previous provider process for this install shut down cleanly,
/// from the local `provider-run.json` marker.
public enum AppAttestPreviousExit: String, Codable, Sendable, Equatable {
    case clean, unclean, unknown
}

/// Why this provider process started, from local lifecycle evidence only.
public enum AppAttestStartReason: String, Codable, Sendable, Equatable {
    case launchd, watchdog, update, manual, unknown
    case stallRestart = "stall_restart"
}

/// Local signing/installation facts that gate `DCAppAttestService.isSupported`.
public struct AppAttestPreflight: Codable, Sendable, Equatable {
    public enum EnvironmentEntitlement: String, Codable, Sendable, Equatable {
        case production, development, absent, invalid
    }

    public enum BundlePathClass: String, Codable, Sendable, Equatable {
        case applications, other
        case userInstall = "user_install"
    }

    public var optInEntitlement: Bool?
    public var environmentEntitlement: EnvironmentEntitlement?
    public var profilePresent: Bool?
    public var profileExpired: Bool?
    public var bundlePathClass: BundlePathClass?

    public init(optInEntitlement: Bool? = nil, environmentEntitlement: EnvironmentEntitlement? = nil,
                profilePresent: Bool? = nil, profileExpired: Bool? = nil, bundlePathClass: BundlePathClass? = nil) {
        self.optInEntitlement = optInEntitlement
        self.environmentEntitlement = environmentEntitlement
        self.profilePresent = profilePresent
        self.profileExpired = profileExpired
        self.bundlePathClass = bundlePathClass
    }

    enum CodingKeys: String, CodingKey {
        case optInEntitlement = "opt_in_entitlement"
        case environmentEntitlement = "environment_entitlement"
        case profilePresent = "profile_present"
        case profileExpired = "profile_expired"
        case bundlePathClass = "bundle_path_class"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        optInEntitlement = c.lenient(CodingKeys.optInEntitlement.rawValue)
        environmentEntitlement = c.lenient(CodingKeys.environmentEntitlement.rawValue)
        profilePresent = c.lenient(CodingKeys.profilePresent.rawValue)
        profileExpired = c.lenient(CodingKeys.profileExpired.rawValue)
        bundlePathClass = c.lenient(CodingKeys.bundlePathClass.rawValue)
    }
}

/// Lifecycle of the stored App Attest key for the account scope of this
/// `ready`. Carries no key identifier.
public struct AppAttestKeyHistory: Codable, Sendable, Equatable {
    public static let maxGenerations = 100
    public static let maxConsecutiveFailures = 1000
    public static let maxVersionLength = 32

    public var generationsLast24h: Int?
    public var lastGenerationAgeSeconds: Int?
    public var lastSuccessAgeSeconds: Int?
    public var consecutiveAssertionFailures: Int?
    public var keyAgeSeconds: Int?
    public var createdBootMatches: Bool?
    public var createdAppVersion: String?

    public init(generationsLast24h: Int? = nil, lastGenerationAgeSeconds: Int? = nil, lastSuccessAgeSeconds: Int? = nil,
                consecutiveAssertionFailures: Int? = nil, keyAgeSeconds: Int? = nil, createdBootMatches: Bool? = nil,
                createdAppVersion: String? = nil) {
        self.generationsLast24h = generationsLast24h
        self.lastGenerationAgeSeconds = lastGenerationAgeSeconds
        self.lastSuccessAgeSeconds = lastSuccessAgeSeconds
        self.consecutiveAssertionFailures = consecutiveAssertionFailures
        self.keyAgeSeconds = keyAgeSeconds
        self.createdBootMatches = createdBootMatches
        self.createdAppVersion = createdAppVersion
    }

    enum CodingKeys: String, CodingKey {
        case generationsLast24h = "generations_last_24h"
        case lastGenerationAgeSeconds = "last_generation_age_seconds"
        case lastSuccessAgeSeconds = "last_success_age_seconds"
        case consecutiveAssertionFailures = "consecutive_assertion_failures"
        case keyAgeSeconds = "key_age_seconds"
        case createdBootMatches = "created_boot_matches"
        case createdAppVersion = "created_app_version"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        generationsLast24h = c.lenient(CodingKeys.generationsLast24h.rawValue)
        lastGenerationAgeSeconds = c.lenient(CodingKeys.lastGenerationAgeSeconds.rawValue)
        lastSuccessAgeSeconds = c.lenient(CodingKeys.lastSuccessAgeSeconds.rawValue)
        consecutiveAssertionFailures = c.lenient(CodingKeys.consecutiveAssertionFailures.rawValue)
        keyAgeSeconds = c.lenient(CodingKeys.keyAgeSeconds.rawValue)
        createdBootMatches = c.lenient(CodingKeys.createdBootMatches.rawValue)
        createdAppVersion = c.lenient(CodingKeys.createdAppVersion.rawValue)
    }

    var isEmpty: Bool { self == AppAttestKeyHistory() }
}

/// APNs code-identity push receipt/reply history for this install, persisted
/// across connections and processes. No tokens, nonces or payloads.
public struct AppAttestPushHistory: Codable, Sendable, Equatable {
    public static let maxPushes = 1000

    public var deviceTokenPresent: Bool?
    public var pushesReceivedLast24h: Int?
    public var lastPushReceivedAgeSeconds: Int?
    public var lastReplySentAgeSeconds: Int?

    public init(deviceTokenPresent: Bool? = nil, pushesReceivedLast24h: Int? = nil,
                lastPushReceivedAgeSeconds: Int? = nil, lastReplySentAgeSeconds: Int? = nil) {
        self.deviceTokenPresent = deviceTokenPresent
        self.pushesReceivedLast24h = pushesReceivedLast24h
        self.lastPushReceivedAgeSeconds = lastPushReceivedAgeSeconds
        self.lastReplySentAgeSeconds = lastReplySentAgeSeconds
    }

    enum CodingKeys: String, CodingKey {
        case deviceTokenPresent = "device_token_present"
        case pushesReceivedLast24h = "pushes_received_last_24h"
        case lastPushReceivedAgeSeconds = "last_push_received_age_seconds"
        case lastReplySentAgeSeconds = "last_reply_sent_age_seconds"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        deviceTokenPresent = c.lenient(CodingKeys.deviceTokenPresent.rawValue)
        pushesReceivedLast24h = c.lenient(CodingKeys.pushesReceivedLast24h.rawValue)
        lastPushReceivedAgeSeconds = c.lenient(CodingKeys.lastPushReceivedAgeSeconds.rawValue)
        lastReplySentAgeSeconds = c.lenient(CodingKeys.lastReplySentAgeSeconds.rawValue)
    }
}

/// Process-level context gathered outside this module (ProviderCore owns the
/// run marker, SIP probes and APNs history) and attached to every `ready`.
public struct AppAttestProcessDiagnostics: Codable, Sendable, Equatable {
    public var processStartedAt: Int64?
    public var previousExit: AppAttestPreviousExit?
    public var startReason: AppAttestStartReason?
    public var consoleUserActive: Bool?
    public var sipEnabled: Bool?
    public var authenticatedRoot: Bool?
    public var preflight: AppAttestPreflight?
    public var pushHistory: AppAttestPushHistory?

    public init(processStartedAt: Int64? = nil, previousExit: AppAttestPreviousExit? = nil,
                startReason: AppAttestStartReason? = nil, consoleUserActive: Bool? = nil,
                sipEnabled: Bool? = nil, authenticatedRoot: Bool? = nil,
                preflight: AppAttestPreflight? = nil, pushHistory: AppAttestPushHistory? = nil) {
        self.processStartedAt = processStartedAt
        self.previousExit = previousExit
        self.startReason = startReason
        self.consoleUserActive = consoleUserActive
        self.sipEnabled = sipEnabled
        self.authenticatedRoot = authenticatedRoot
        self.preflight = preflight
        self.pushHistory = pushHistory
    }

    enum CodingKeys: String, CodingKey {
        case processStartedAt = "process_started_at"
        case previousExit = "previous_exit"
        case startReason = "start_reason"
        case consoleUserActive = "console_user_active"
        case sipEnabled = "sip_enabled"
        case authenticatedRoot = "authenticated_root"
        case preflight
        case pushHistory = "push_history"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        processStartedAt = c.lenient(CodingKeys.processStartedAt.rawValue)
        previousExit = c.lenient(CodingKeys.previousExit.rawValue)
        startReason = c.lenient(CodingKeys.startReason.rawValue)
        consoleUserActive = c.lenient(CodingKeys.consoleUserActive.rawValue)
        sipEnabled = c.lenient(CodingKeys.sipEnabled.rawValue)
        authenticatedRoot = c.lenient(CodingKeys.authenticatedRoot.rawValue)
        preflight = c.lenient(CodingKeys.preflight.rawValue)
        pushHistory = c.lenient(CodingKeys.pushHistory.rawValue)
    }
}

extension AppAttestShadowPayload {
    /// Copies process diagnostics onto a `ready` reply. Never signed.
    mutating func attach(_ diagnostics: AppAttestProcessDiagnostics) {
        processStartedAt = diagnostics.processStartedAt
        previousExit = diagnostics.previousExit
        startReason = diagnostics.startReason
        consoleUserActive = diagnostics.consoleUserActive
        sipEnabled = diagnostics.sipEnabled
        authenticatedRoot = diagnostics.authenticatedRoot
        preflight = diagnostics.preflight
        pushHistory = diagnostics.pushHistory
    }
}
