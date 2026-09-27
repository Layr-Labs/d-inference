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

    func testAvailabilityReasonsPreserveExistingFailureClasses() throws {
        let signed: [String: Any] = [AppAttestEntitlementPolicy.optIn: ["CDhash"]]
        let cases: [([String: Any], String, ShadowFailure, AppAttestAvailabilityReason)] = [
            ([:], "production", .notConfigured, .optInMissing),
            ([AppAttestEntitlementPolicy.optIn: "invalid"], "production", .notConfigured, .optInMissing),
            (signed.merging([AppAttestEntitlementPolicy.environment: true]) { _, new in new },
             "production", .notConfigured, .environmentEntitlementInvalid),
            (signed.merging([AppAttestEntitlementPolicy.environment: "development"]) { _, new in new },
             "production", .environmentMismatch, .environmentMismatch)
        ]
        for (entitlements, environment, result, reason) in cases {
            XCTAssertThrowsError(try AppAttestEntitlementPolicy.validateAvailability(entitlements, expectedEnvironment: environment)) {
                let failure = $0 as? AppAttestAvailabilityFailure
                XCTAssertEqual(failure?.failure, result)
                XCTAssertEqual(failure?.reason, reason)
            }
        }
        try AppAttestEntitlementPolicy.validateAvailability(signed, expectedEnvironment: "production")
        XCTAssertThrowsError(try AppAttestEntitlementPolicy.validateAvailability(signed, expectedEnvironment: "invalid")) {
            XCTAssertEqual($0 as? ShadowFailure, .invalidRequest)
        }
    }

    func testAvailabilityGuardsReportClosedReasons() throws {
        XCTAssertThrowsError(try AppAttestAvailabilityChecks.requireOS(26)) {
            XCTAssertEqual(($0 as? AppAttestAvailabilityFailure)?.reason, .osBelow27)
            XCTAssertEqual(appAttestFailure($0), .unsupported)
        }
        try AppAttestAvailabilityChecks.requireOS(27)
        XCTAssertThrowsError(try AppAttestAvailabilityChecks.requireAppBundle("")) {
            XCTAssertEqual(($0 as? AppAttestAvailabilityFailure)?.reason, .notAppBundle)
            XCTAssertEqual(appAttestFailure($0), .notConfigured)
        }
        try AppAttestAvailabilityChecks.requireAppBundle("app")
        XCTAssertThrowsError(try AppAttestAvailabilityChecks.requireSigningInfo(nil)) {
            XCTAssertEqual(($0 as? AppAttestAvailabilityFailure)?.reason, .signingInfoUnavailable)
            XCTAssertEqual(appAttestFailure($0), .notConfigured)
        }
        _ = try AppAttestAvailabilityChecks.requireSigningInfo([:])
        XCTAssertThrowsError(try AppAttestEntitlementPolicy.validateAvailability(
            AppAttestAvailabilityChecks.requireSigningInfo([:]), expectedEnvironment: "production")) {
            XCTAssertEqual(($0 as? AppAttestAvailabilityFailure)?.reason, .optInMissing)
            XCTAssertEqual(appAttestFailure($0), .notConfigured)
        }
        XCTAssertThrowsError(try AppAttestAvailabilityChecks.requireSupported(false)) {
            XCTAssertEqual(($0 as? AppAttestAvailabilityFailure)?.reason, .isSupportedFalse)
            XCTAssertEqual(appAttestFailure($0), .unsupported)
        }
        try AppAttestAvailabilityChecks.requireSupported(true)
    }
}
