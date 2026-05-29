// TEST-ONLY harness: validate the Secure-Enclave ECIES wrap/unwrap +
// KEK/DEK round-trip on a REAL Secure Enclave — WITHOUT code signing.
//
// It uses a TRANSIENT SE key (PersistentEnclaveKey.makeTransient:
// kSecAttrIsPermanent=false, no keychain access group), so it needs no
// `keychain-access-groups` entitlement and runs from a plain unsigned
// `swift build` binary. Run:
//
//   swift build --product kv-se-harness
//   .build/debug/kv-se-harness
//
// Exercises, on the real Secure Enclave:
//   - SE key generation (transient)
//   - ECIES wrap (public-key) + unwrap (SE private key) — the new code in
//     PersistentEnclaveKey+ECIES / SecureEnclaveKeyWrappingService
//   - KVCacheKEK: generate -> SE-wrap -> store -> read -> SE-unwrap,
//     recovering the SAME KEK material (KEK storage is in-memory here;
//     keychain PERSISTENCE of the key is the one part that needs a signed
//     build, and it's the same SecItem path the attestation key uses).
//   - DEK wrap/unwrap under the recovered KEK
//
// Prints PASS/FAIL; exits non-zero on failure. NOT a product, NOT shipped.

import CryptoKit
import Foundation
import ProviderCore

func harnessFail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("\nFAIL: \(msg)\n".utf8))
    exit(1)
}

print("== SE ECIES + KEK harness (transient SE key, unsigned) ==")
print("SE available: \(PersistentEnclaveKey.isAvailable)")

guard PersistentEnclaveKey.isAvailable else {
    harnessFail("Secure Enclave not available on this machine")
}

do {
    // Transient SE key — real Secure Enclave, no keychain, no entitlement.
    let se = try PersistentEnclaveKey.makeTransient()
    print("✓ transient SE key created (pub \(se.publicKeyRaw.count) bytes)")

    // 1) Direct ECIES round-trip on the real SE key (the new code path:
    //    SecKeyCreateEncryptedData / SecKeyCreateDecryptedData with
    //    .eciesEncryptionStandardX963SHA256AESGCM).
    let probe = Data("ecies-probe-payload-\(UUID().uuidString)".utf8)
    let sealed = try se.eciesEncrypt(probe)
    let opened = try se.eciesDecrypt(sealed)
    guard opened == probe else { harnessFail("ECIES round-trip mismatch on real SE key") }
    print("✓ ECIES wrap+unwrap on real SE (ciphertext \(sealed.count) bytes; SE-private decrypt)")

    // 2) KEK: generate -> SE-wrap -> store -> read -> SE-unwrap.
    //    Both KEK instances share the same transient SE key + storage
    //    (the key is in-memory; we're validating wrap/unwrap, not
    //    keychain persistence).
    let wrapper = SecureEnclaveKeyWrappingService(enclaveKey: se)
    let storage = InMemoryWrappedKEKStorage(identifier: "harness")
    let kek1 = KVCacheKEK(wrapper: wrapper, storage: storage)
    let k1 = try await kek1.loadOrCreate()
    let k1raw = k1.withUnsafeBytes { Data($0) }

    let kek2 = KVCacheKEK(wrapper: wrapper, storage: storage)
    let k2 = try await kek2.loadOrCreate()  // reads stored wrapped KEK -> SE-unwrap
    let k2raw = k2.withUnsafeBytes { Data($0) }
    guard k1raw == k2raw else {
        harnessFail("KEK material differed after store + SE-unwrap (wrap/unwrap broken)")
    }
    print("✓ KEK generated, SE-wrapped, recovered identically via SE-unwrap")

    // 3) DEK wrap/unwrap under the recovered KEK.
    let aad = Data("harness-metadata-aad".utf8)
    let (dek, wrappedDEK) = try await kek1.freshDEK(aad: aad)
    let dekRaw = dek.withUnsafeBytes { Data($0) }
    let recovered = try await kek2.unwrap(wrappedDEK: wrappedDEK, aad: aad)
    let recRaw = recovered.withUnsafeBytes { Data($0) }
    guard dekRaw == recRaw else { harnessFail("DEK round-trip under recovered KEK mismatch") }
    print("✓ DEK wrap/unwrap under recovered KEK")

    // 4) Tamper check: a flipped wrapped-DEK byte must fail SE-unwrap auth.
    var tampered = wrappedDEK
    tampered[tampered.count - 1] ^= 0xFF
    do {
        _ = try await kek2.unwrap(wrappedDEK: tampered, aad: aad)
        harnessFail("tampered wrapped DEK unexpectedly unwrapped")
    } catch { print("✓ tampered wrapped DEK rejected") }

    print("\nPASS: Secure-Enclave ECIES + KEK/DEK wrap/unwrap verified on real hardware.")
} catch {
    harnessFail("threw: \(error)")
}
