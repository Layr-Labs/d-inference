import Foundation
import Security
import XCTest
@testable import BootContinuity

final class BootKeyHardwareTests: XCTestCase {
    func testExplicitlyRequestedSignedAppStaticPolicy() throws {
        guard ProcessInfo.processInfo.environment["DARKBLOOM_TEST_BOOT_KEY_HARDWARE"] == "1",
              let path = ProcessInfo.processInfo.environment["DARKBLOOM_TEST_SIGNED_APP_PATH"] else {
            throw XCTSkip("Requires explicit installed signed-app path")
        }
        let app = URL(fileURLWithPath: path)
        let executable = app.appendingPathComponent("Contents/MacOS/darkbloom")
        var code: SecStaticCode?
        XCTAssertEqual(SecStaticCodeCreateWithPath(executable as CFURL, SecCSFlags(), &code), errSecSuccess)
        let candidate = try XCTUnwrap(code)
        var requirement: SecRequirement?
        let expression = "anchor apple generic and identifier \"io.darkbloom.provider\" and certificate leaf[subject.OU] = \"SLDQ2GJ6TL\""
        XCTAssertEqual(SecRequirementCreateWithString(expression as CFString, SecCSFlags(), &requirement), errSecSuccess)
        XCTAssertEqual(SecStaticCodeCheckValidity(candidate, SecCSFlags(rawValue: kSecCSStrictValidate), requirement), errSecSuccess)
        var raw: CFDictionary?
        XCTAssertEqual(SecCodeCopySigningInformation(candidate, SecCSFlags(rawValue: kSecCSSigningInformation), &raw), errSecSuccess)
        let info = try XCTUnwrap(raw as? [String: Any])
        try BootApplicationPolicy.validate(
            identifier: XCTUnwrap(info[kSecCodeInfoIdentifier as String] as? String),
            teamID: XCTUnwrap(info[kSecCodeInfoTeamIdentifier as String] as? String),
            hardenedRuntime: XCTUnwrap(info[kSecCodeInfoFlags as String] as? UInt32) & 0x10000 != 0,
            entitlements: XCTUnwrap(info[kSecCodeInfoEntitlementsDict as String] as? [String: Any]),
            executable: XCTUnwrap(info[kSecCodeInfoMainExecutable as String] as? URL),
            bundle: app, bundleExecutable: executable)
        // This validates stored signature metadata, not execution of our new
        // currentReleaseID() function inside the released main process.
    }

    func testExplicitlyRequestedUnentitledKeychainRead() throws {
        guard ProcessInfo.processInfo.environment["DARKBLOOM_TEST_BOOT_KEY_HARDWARE"] == "1" else {
            throw XCTSkip("Requires explicit local hardware-test opt-in")
        }
        // Test binaries are not signed/provisioned for the provider access group.
        // This is read-only, uses a test-only namespace, and must not show UI.
        let context = try makeContext(account: "unentitled-read-control")
        XCTAssertThrowsError(try DataProtectionBootIdentityStore().read(context: context)) {
            XCTAssertEqual($0 as? BootCustodyError, .keychainFailure(errSecMissingEntitlement))
        }
    }

    func testExplicitlyRequestedHardwareRoundTrip() throws {
        guard ProcessInfo.processInfo.environment["DARKBLOOM_TEST_BOOT_KEY_HARDWARE"] == "1" else {
            throw XCTSkip("Requires explicit local hardware-test opt-in")
        }
        let engine = SecureEnclaveBootKeyEngine()
        let context = try makeContext()
        let original = try BootKeySession.create(context: context, activation: .experimental, engine: engine)
        // The record stays in test memory. No Keychain or filesystem persistence.
        let recovered = try BootKeySession.recover(record: original.storageRecord(), context: context, activation: .experimental, engine: engine)
        XCTAssertEqual(original.publicKey, recovered.publicKey)
        let challenge = try BootContinuationChallenge(nonce: Data(repeating: 7, count: 32), processPublicKey: Data(repeating: 8, count: 32))
        _ = try recovered.provePossession(challenge)
    }
}
