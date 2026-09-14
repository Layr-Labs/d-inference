import Foundation
import SandboxSecurity
import XCTest

final class SandboxSecureEnclaveKeyTests: XCTestCase {
    func testTransientSecureEnclaveWrapRoundTripAndRandomization() throws {
        try XCTSkipUnless(
            SandboxSecureEnclaveKey.isAvailable,
            "test requires Apple Secure Enclave hardware"
        )
        let key = try SandboxSecureEnclaveKey.makeTransient()
        let plaintext = Data("sandbox data-encryption key".utf8)

        let first = try key.wrap(plaintext)
        let second = try key.wrap(plaintext)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try key.unwrap(first), plaintext)
        XCTAssertEqual(try key.unwrap(second), plaintext)
        try key.selfTest()
    }

    func testTransientSecureEnclaveRejectsTamperAndWrongIdentity() throws {
        try XCTSkipUnless(
            SandboxSecureEnclaveKey.isAvailable,
            "test requires Apple Secure Enclave hardware"
        )
        let key = try SandboxSecureEnclaveKey.makeTransient()
        let otherKey = try SandboxSecureEnclaveKey.makeTransient()
        var wrapped = try key.wrap(Data(repeating: 0x42, count: 32))

        wrapped[wrapped.count / 2] ^= 0x01
        XCTAssertThrowsError(try key.unwrap(wrapped))

        let untampered = try key.wrap(Data(repeating: 0x24, count: 32))
        XCTAssertThrowsError(try otherKey.unwrap(untampered))
    }

    func testPublicKeyUsesUncompressedP256Encoding() throws {
        try XCTSkipUnless(
            SandboxSecureEnclaveKey.isAvailable,
            "test requires Apple Secure Enclave hardware"
        )
        let key = try SandboxSecureEnclaveKey.makeTransient()
        let publicKey = try key.publicKeyX963

        XCTAssertEqual(publicKey.count, 65)
        XCTAssertEqual(publicKey.first, 0x04)
    }
}
