import Foundation
import XCTest
@testable import ProviderAppAttest

final class WorkerRuntimeDiagnosticsTests: XCTestCase {
    func testOnlyKnownNonsecretEntitlementsAreReportedWithTheirActualTypes() throws {
        let values = AppAttestWorkerRuntimeDiagnostics.knownEntitlements([
            AppAttestEntitlementPolicy.optIn: ["CDhash"],
            "com.apple.application-identifier": "TEAM.io.example",
            "keychain-access-groups": ["TEAM.io.example"],
            "com.apple.security.app-sandbox": true,
            "secret": "do-not-emit", "prompt": "do-not-emit",
        ])
        XCTAssertEqual(Set(values.keys), Set(AppAttestWorkerRuntimeDiagnostics.entitlementNames))
        XCTAssertEqual(values[AppAttestEntitlementPolicy.optIn], .strings(["CDhash"]))
        XCTAssertEqual(values["com.apple.application-identifier"], .string("TEAM.io.example"))
        XCTAssertEqual(values["keychain-access-groups"], .strings(["TEAM.io.example"]))
        XCTAssertEqual(values["com.apple.security.app-sandbox"], .boolean(true))
        XCTAssertEqual(values[AppAttestEntitlementPolicy.environment], .absent)
        let encoded = try JSONEncoder().encode(values)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("do-not-emit"))
        XCTAssertEqual(try JSONDecoder().decode([String: AppAttestWorkerRuntimeDiagnostics.EntitlementValue].self, from: encoded), values)
    }

    func testInvalidAndUnboundedEntitlementsDoNotLeakTheirContents() throws {
        let values = AppAttestWorkerRuntimeDiagnostics.knownEntitlements([
            AppAttestEntitlementPolicy.optIn: String(repeating: "x", count: 257),
            "keychain-access-groups": Array(repeating: "group", count: 9),
            "com.apple.security.app-sandbox": 1,
            "com.apple.application-identifier": ["private": "do-not-emit"],
            "com.apple.developer.team-identifier": Data("do-not-emit".utf8),
        ])
        for key in [AppAttestEntitlementPolicy.optIn, "keychain-access-groups", "com.apple.security.app-sandbox",
                    "com.apple.application-identifier", "com.apple.developer.team-identifier"] {
            XCTAssertEqual(values[key], .invalid)
        }
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(values), as: UTF8.self).contains("do-not-emit"))
    }
}
