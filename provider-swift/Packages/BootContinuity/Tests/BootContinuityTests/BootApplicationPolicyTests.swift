import Foundation
import LocalAuthentication
import Security
import XCTest
@testable import BootContinuity

final class BootApplicationPolicyTests: XCTestCase {
    private let app = URL(fileURLWithPath: "/Applications/Darkbloom.app")
    private var executable: URL { app.appendingPathComponent("Contents/MacOS/darkbloom") }
    private var allowed: [String: Any] {
        ["com.apple.application-identifier": BootApplicationPolicy.applicationID,
         "keychain-access-groups": [DataProtectionBootIdentityStore.accessGroup]]
    }

    func testOnlyExpectedMainAppScopePasses() throws {
        try check()
        XCTAssertThrowsError(try check(identifier: "darkbloom-enclave"))
        XCTAssertThrowsError(try check(team: "OTHERTEAM"))
        XCTAssertThrowsError(try check(runtime: false))
        XCTAssertThrowsError(try check(entitlements: [:]))
        XCTAssertThrowsError(try check(path: app.appendingPathComponent("Contents/MacOS/darkbloom-enclave")))
        var otherGroup = allowed
        otherGroup["keychain-access-groups"] = ["OTHERTEAM.io.darkbloom.provider"]
        XCTAssertThrowsError(try check(entitlements: otherGroup))
        for entitlement in BootApplicationPolicy.forbiddenEntitlements {
            var unsafe = allowed
            unsafe[entitlement] = true
            XCTAssertThrowsError(try check(entitlements: unsafe))
            unsafe[entitlement] = "unexpected"
            XCTAssertThrowsError(try check(entitlements: unsafe))
            unsafe[entitlement] = 0
            XCTAssertThrowsError(try check(entitlements: unsafe))
            unsafe[entitlement] = false
            try check(entitlements: unsafe)
        }
    }

    func testLiveTestBinaryIsRejectedBeforeCustody() {
        XCTAssertThrowsError(try SignedBootApplicationScope().currentReleaseID()) {
            XCTAssertEqual($0 as? BootCustodyError, .applicationNotPermitted)
        }
    }

    func testKeychainQueryCannotFallBackToLegacyOrSynchronizableStorage() throws {
        let query = DataProtectionBootIdentityStore.baseQuery(context: try makeContext())
        XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, DataProtectionBootIdentityStore.accessGroup)
        XCTAssertEqual((query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed, true)
        XCTAssertNil(query[kSecAttrAccess as String], "No legacy keychain ACL path")
    }

    func testLocatorBindsEveryAuthoritativeContextField() throws {
        let original = DataProtectionBootIdentityStore.accountLocator(context: try makeContext())
        for context in try [makeContext(account: "other"), makeContext(device: "other"),
                            makeContext(origin: "https://other.example"), makeContext(release: "other"), makeContext(generation: 2)] {
            XCTAssertNotEqual(original, DataProtectionBootIdentityStore.accountLocator(context: context))
        }
    }

    private func check(identifier: String = BootApplicationPolicy.identifier, team: String = BootApplicationPolicy.teamID,
                       runtime: Bool = true, entitlements: [String: Any]? = nil, path: URL? = nil) throws {
        try BootApplicationPolicy.validate(identifier: identifier, teamID: team, hardenedRuntime: runtime,
                                            entitlements: entitlements ?? allowed, executable: path ?? executable,
                                            bundle: app, bundleExecutable: executable)
    }
}
