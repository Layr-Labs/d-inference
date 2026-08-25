import Foundation
import SandboxSecurity
import XCTest

final class SandboxEntitlementsTests: XCTestCase {
    func testProductionEntitlementsAuthorizeDedicatedKeychainGroup() throws {
        let entitlements = try loadEntitlements(
            named: "DarkbloomSandbox.entitlements"
        )
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

    func testDevelopmentEntitlementsRemainAdHocSignable() throws {
        let entitlements = try loadEntitlements(
            named: "DarkbloomSandboxDevelopment.entitlements"
        )

        XCTAssertEqual(
            entitlements["com.apple.security.virtualization"] as? Bool,
            true
        )
        XCTAssertNil(entitlements["keychain-access-groups"])
        XCTAssertEqual(entitlements.count, 1)
    }

    private func loadEntitlements(
        named name: String
    ) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
            .appendingPathComponent(name)
        let object = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: url),
            options: [],
            format: nil
        )
        return try XCTUnwrap(object as? [String: Any])
    }
}
