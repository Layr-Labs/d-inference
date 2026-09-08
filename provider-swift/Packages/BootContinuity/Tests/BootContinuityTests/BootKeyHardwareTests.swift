import Foundation
import XCTest
@testable import BootContinuity

final class BootKeyHardwareTests: XCTestCase {
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
