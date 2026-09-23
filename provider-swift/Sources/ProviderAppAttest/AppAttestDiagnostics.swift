import Foundation

/// Closed, non-authoritative client diagnostics. Neither value enters the
/// App Attest client hash or changes the result used by coordinator policy.
public enum AppAttestAvailabilityReason: String, Codable, Sendable {
    case osBelow27 = "os_below_27"
    case notAppBundle = "not_app_bundle"
    case signingInfoUnavailable = "signing_info_unavailable"
    case optInMissing = "opt_in_missing"
    case environmentEntitlementInvalid = "environment_entitlement_invalid"
    case environmentMismatch = "environment_mismatch"
    case isSupportedFalse = "is_supported_false"
}

public enum AppAttestAppleErrorSource: String, Codable, Sendable, Error {
    case callbackWithoutNSError = "callback_without_nserror"
    case proofOversize = "proof_oversize"
}

struct AppAttestAvailabilityFailure: Error, Sendable {
    let failure: ShadowFailure
    let reason: AppAttestAvailabilityReason
}

enum AppAttestAvailabilityChecks {
    static func requireOS(_ majorVersion: Int) throws {
        guard majorVersion >= 27 else {
            throw AppAttestAvailabilityFailure(failure: .unsupported, reason: .osBelow27)
        }
    }

    static func requireAppBundle(_ pathExtension: String) throws {
        guard pathExtension == "app" else {
            throw AppAttestAvailabilityFailure(failure: .notConfigured, reason: .notAppBundle)
        }
    }

    static func requireSigningInfo(_ entitlements: [String: Any]?) throws -> [String: Any] {
        guard let entitlements else {
            throw AppAttestAvailabilityFailure(failure: .notConfigured, reason: .signingInfoUnavailable)
        }
        return entitlements
    }

    static func requireSupported(_ supported: Bool) throws {
        guard supported else {
            throw AppAttestAvailabilityFailure(failure: .unsupported, reason: .isSupportedFalse)
        }
    }
}
