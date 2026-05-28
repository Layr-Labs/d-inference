import CryptoKit
import Foundation
import Testing
@testable import ProviderCore

// Exercises the in-memory `KeyWrappingService` implementation. The
// SE-backed implementation is covered separately in
// `KVCacheKEKTests` (which skips when the Secure Enclave isn't
// available or the binary lacks the keychain-access-groups
// entitlement). The protocol-level invariants — round-trip equality,
// nonce uniqueness, tamper detection — are the same regardless of
// backend, so testing them once against the in-memory impl is
// sufficient.

@Test
func inMemoryWrapUnwrapRoundtrip() throws {
    let svc = InMemoryKeyWrappingService()
    let plaintext = Data("the quick brown fox jumps over the lazy dog".utf8)

    let wrapped = try svc.wrap(plaintext)
    #expect(wrapped.count >= plaintext.count + 12 + 16)  // nonce + ct + tag

    let unwrapped = try svc.unwrap(wrapped)
    #expect(unwrapped == plaintext)
}

@Test
func inMemoryWrapProducesUniqueCiphertexts() throws {
    let svc = InMemoryKeyWrappingService()
    let plaintext = Data(repeating: 0x42, count: 64)

    let w1 = try svc.wrap(plaintext)
    let w2 = try svc.wrap(plaintext)
    #expect(w1 != w2, "wrap must include a fresh nonce per call")

    // Both decrypt to the same plaintext.
    #expect(try svc.unwrap(w1) == plaintext)
    #expect(try svc.unwrap(w2) == plaintext)
}

@Test
func inMemoryWrapHandlesEmpty() throws {
    let svc = InMemoryKeyWrappingService()
    let wrapped = try svc.wrap(Data())
    let unwrapped = try svc.unwrap(wrapped)
    #expect(unwrapped.isEmpty)
}

@Test
func inMemoryUnwrapTamperedCiphertextFails() throws {
    let svc = InMemoryKeyWrappingService()
    let plaintext = Data("authentic payload".utf8)
    var wrapped = try svc.wrap(plaintext)

    // Flip one byte inside the ciphertext (offset 12 = first byte
    // after the nonce).
    #expect(wrapped.count > 12)
    wrapped[12] ^= 0xFF

    #expect(throws: KeyWrappingError.self) {
        _ = try svc.unwrap(wrapped)
    }
}

@Test
func inMemoryUnwrapTamperedTagFails() throws {
    let svc = InMemoryKeyWrappingService()
    let plaintext = Data("authentic payload".utf8)
    var wrapped = try svc.wrap(plaintext)

    // Flip the last byte (inside the GCM tag).
    let last = wrapped.count - 1
    wrapped[last] ^= 0xFF

    #expect(throws: KeyWrappingError.self) {
        _ = try svc.unwrap(wrapped)
    }
}

@Test
func inMemoryUnwrapWithDifferentKeyFails() throws {
    let svcA = InMemoryKeyWrappingService(
        key: SymmetricKey(data: Data(repeating: 0xAA, count: 32)),
        identifier: "A"
    )
    let svcB = InMemoryKeyWrappingService(
        key: SymmetricKey(data: Data(repeating: 0xBB, count: 32)),
        identifier: "B"
    )

    let wrapped = try svcA.wrap(Data("hello".utf8))
    #expect(throws: KeyWrappingError.self) {
        _ = try svcB.unwrap(wrapped)
    }
}

@Test
func inMemoryUnwrapMalformedDataFails() throws {
    let svc = InMemoryKeyWrappingService()
    #expect(throws: KeyWrappingError.self) {
        _ = try svc.unwrap(Data("not actually ciphertext".utf8))
    }
    #expect(throws: KeyWrappingError.self) {
        _ = try svc.unwrap(Data())
    }
}
