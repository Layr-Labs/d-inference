import Foundation

/// Local readiness only. The coordinator still verifies the attested environment
/// from the Apple-signed aaguid; a missing environment entitlement is no proof of
/// either environment. Developer ID profiles can grant just the CDhash opt-in.
enum AppAttestEntitlementPolicy {
    static let optIn = "com.apple.developer.devicecheck.app-attest-opt-in"
    static let environment = "com.apple.developer.devicecheck.appattest-environment"

    static func validate(_ entitlements: [String: Any], expectedEnvironment: String) throws {
        guard ["production", "development"].contains(expectedEnvironment) else {
            throw ShadowFailure.invalidRequest
        }
        let modes = entitlements[optIn] as? [String]
        guard (entitlements[optIn] as? String) == "CDhash" || modes?.contains("CDhash") == true else {
            throw ShadowFailure.notConfigured
        }
        if let value = entitlements[environment] {
            guard let configured = value as? String,
                  ["production", "development"].contains(configured) else {
                throw ShadowFailure.notConfigured
            }
            guard configured == expectedEnvironment else { throw ShadowFailure.environmentMismatch }
        }
    }
}
