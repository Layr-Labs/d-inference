import Foundation
import SandboxSecurity
import XCTest

final class SandboxEntitlementsTests: XCTestCase {
    func testProductionEntitlementsAuthorizeDedicatedKeychainGroup() throws {
        let entitlementsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/DarkbloomSandbox.entitlements")
        let object = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: entitlementsURL),
            options: [],
            format: nil
        )
        let entitlements = try XCTUnwrap(object as? [String: Any])
        let groups = try XCTUnwrap(
            entitlements["keychain-access-groups"] as? [String]
        )

        XCTAssertEqual(
            groups,
            [SandboxSecureEnclaveKey.defaultAccessGroup]
        )
        XCTAssertNil(
            entitlements["com.apple.security.keychain-access-groups"],
            "the prefixed key is not a valid code-signing entitlement"
        )
        XCTAssertEqual(
            entitlements["com.apple.security.virtualization"] as? Bool,
            true
        )
    }
}
