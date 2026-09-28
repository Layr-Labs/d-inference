import Foundation

/// Local readiness only. The coordinator still verifies the attested environment
/// from the Apple-signed aaguid; a missing environment entitlement is no proof of
/// either environment. Developer ID profiles can grant just the CDhash opt-in.
enum AppAttestEntitlementPolicy {
    static let optIn = "com.apple.developer.devicecheck.app-attest-opt-in"
    static let environment = "com.apple.developer.devicecheck.appattest-environment"

    static func validate(_ entitlements: [String: Any], expectedEnvironment: String) throws {
        if let issue = validationIssue(entitlements, expectedEnvironment: expectedEnvironment) {
            throw issue.failure
        }
    }

    static func validateAvailability(_ entitlements: [String: Any], expectedEnvironment: String) throws {
        if let issue = validationIssue(entitlements, expectedEnvironment: expectedEnvironment) {
            if let reason = issue.reason {
                throw AppAttestAvailabilityFailure(failure: issue.failure, reason: reason)
            }
            throw issue.failure
        }
    }

    private static func validationIssue(_ entitlements: [String: Any], expectedEnvironment: String) -> (failure: ShadowFailure, reason: AppAttestAvailabilityReason?)? {
        guard ["production", "development"].contains(expectedEnvironment) else {
            return (.invalidRequest, nil)
        }
        let modes = entitlements[optIn] as? [String]
        guard (entitlements[optIn] as? String) == "CDhash" || modes?.contains("CDhash") == true else {
            return (.notConfigured, .optInMissing)
        }
        if let value = entitlements[environment] {
            guard let configured = value as? String,
                  ["production", "development"].contains(configured) else {
                return (.notConfigured, .environmentEntitlementInvalid)
            }
            guard configured == expectedEnvironment else { return (.environmentMismatch, .environmentMismatch) }
        }
        return nil
    }
}
