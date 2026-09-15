import XCTest
@testable import ProviderAppAttest

final class AppAttestEntitlementPolicyTests: XCTestCase {
    func testMacOptInOnlyProfileAllowsAttemptWithoutGuessingEnvironment() throws {
        let signed: [String: Any] = [AppAttestEntitlementPolicy.optIn: ["CDhash"]]
        // Readiness accepts either requested environment here; only Apple's
        // attestation and the coordinator verifier can establish the real one.
        for environment in ["production", "development"] {
            try AppAttestEntitlementPolicy.validate(signed, expectedEnvironment: environment)
        }
        try AppAttestEntitlementPolicy.validate(
            [AppAttestEntitlementPolicy.optIn: "CDhash"], expectedEnvironment: "production")
    }

    func testLegacyProfileWithoutOptInStaysUnconfigured() {
        for signed: [String: Any] in [
            [:],
            [AppAttestEntitlementPolicy.environment: "production"],
            ["com.apple.developer.aps-environment": "production"]
        ] {
            XCTAssertThrowsError(try AppAttestEntitlementPolicy.validate(signed, expectedEnvironment: "production")) {
                XCTAssertEqual($0 as? ShadowFailure, .notConfigured)
            }
        }
    }

    func testExplicitEnvironmentMismatchIsRejected() throws {
        let signed: [String: Any] = [
            AppAttestEntitlementPolicy.optIn: ["CDhash"],
            AppAttestEntitlementPolicy.environment: "development"
        ]
        try AppAttestEntitlementPolicy.validate(signed, expectedEnvironment: "development")
        XCTAssertThrowsError(try AppAttestEntitlementPolicy.validate(signed, expectedEnvironment: "production")) {
            XCTAssertEqual($0 as? ShadowFailure, .environmentMismatch)
        }
    }

    func testMalformedGrantsDoNotPassReadiness() {
        let invalidModes: [Any] = [true, "*", [String](), ["future-mode"], ["CDhash", true] as [Any]]
        for modes in invalidModes {
            XCTAssertThrowsError(try AppAttestEntitlementPolicy.validate(
                [AppAttestEntitlementPolicy.optIn: modes], expectedEnvironment: "production")) {
                XCTAssertEqual($0 as? ShadowFailure, .notConfigured)
            }
        }
        for value: Any in [true, ["production"], "*"] {
            XCTAssertThrowsError(try AppAttestEntitlementPolicy.validate(
                [AppAttestEntitlementPolicy.optIn: ["CDhash"], AppAttestEntitlementPolicy.environment: value],
                expectedEnvironment: "production")) {
                XCTAssertEqual($0 as? ShadowFailure, .notConfigured)
            }
        }
    }
}
