// Golden-value tests for `Sequence<UInt8>.hexString`.
//
// hexString backs attestation-critical hashes (BinaryHasher digests,
// SecureEnclaveIdentity.publicKeyHex). A silent output change here would
// alter every provider-reported hash fleet-wide, so these tests pin the
// exact output rather than just properties of it.

import CryptoKit
import Foundation
import Testing
@testable import ProviderCore

@Test func hexStringOfEmptyInputIsEmpty() {
    #expect([UInt8]().hexString == "")
    #expect(Data().hexString == "")
}

@Test func hexStringGoldenValuesForSingleBytes() {
    #expect([UInt8]([0x00]).hexString == "00")
    #expect([UInt8]([0x0f]).hexString == "0f")
}

@Test func hexStringGoldenValueForMultipleBytes() {
    #expect([UInt8]([0xa5, 0xff]).hexString == "a5ff")
}

@Test func hexStringMatchesReferenceImplementationForAll256ByteValues() {
    let allBytes = [UInt8](0x00...0xff)
    let reference = allBytes.map { String(format: "%02x", $0) }.joined()
    #expect(allBytes.hexString == reference)
    #expect(Data(allBytes).hexString == reference)
}

@Test func hexStringOfSHA256DigestMatchesPinnedVector() {
    // Pinned once via `printf 'darkbloom' | shasum -a 256`. Do NOT update
    // this constant to make the test pass — a mismatch means the wire
    // format of every provider-reported hash changed.
    let digest = SHA256.hash(data: Data("darkbloom".utf8))
    #expect(digest.hexString == "8794f3753bd7835608c45f36d4123311248f6dcb0904ce4950aad1e3740ecb8e")
}

@Test func hexStringIsAlwaysLowercase() {
    let hex = [UInt8](0x00...0xff).hexString
    #expect(hex == hex.lowercased())
    #expect(hex.allSatisfy { $0.isNumber || ("a"..."f").contains($0) })
}
