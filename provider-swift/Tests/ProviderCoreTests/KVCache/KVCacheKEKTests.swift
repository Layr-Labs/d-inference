import CryptoKit
import Foundation
import Testing
@testable import ProviderCore

// KVCacheKEK tests run against the in-memory wrapping service +
// in-memory storage so they don't require Secure Enclave or the
// keychain-access-groups entitlement. The SE-backed wrap path is
// covered separately in `kekRoundtripsViaSecureEnclave` (skips
// gracefully on missing SE / missing entitlement). The Keychain
// storage path is covered by `kekRoundtripsViaKeychainStorage` (same
// skip semantics).
//
// Each test uses an independent storage instance so they don't
// collide.

private func testKEK(
    wrapper: KeyWrappingService = InMemoryKeyWrappingService(),
    storage: WrappedKEKStorage? = nil
) -> KVCacheKEK {
    return KVCacheKEK(
        wrapper: wrapper,
        storage: storage ?? InMemoryWrappedKEKStorage(identifier: UUID().uuidString)
    )
}

@Test
func kekLoadOrCreateGeneratesOnFirstCall() async throws {
    let kek = testKEK()

    #expect(try await kek.existsInStorage() == false)

    let first = try await kek.loadOrCreate()

    #expect(try await kek.existsInStorage() == true)

    // Subsequent loadOrCreate returns the same key (in-memory cache hit).
    let second = try await kek.loadOrCreate()
    #expect(
        first.withUnsafeBytes { Data($0) } == second.withUnsafeBytes { Data($0) },
        "loadOrCreate must be idempotent within a process"
    )
}

@Test
func kekPersistsAcrossActorInstances() async throws {
    // Two actor instances pointed at the same storage simulate two
    // consecutive process launches. The second instance must see the
    // exact same KEK material.
    let wrapKey = SymmetricKey(data: Data(repeating: 0x42, count: 32))
    let wrapper = InMemoryKeyWrappingService(key: wrapKey, identifier: "shared")
    let storage = InMemoryWrappedKEKStorage(identifier: "shared")

    let first = KVCacheKEK(wrapper: wrapper, storage: storage)
    let kek1 = try await first.loadOrCreate()
    let raw1 = kek1.withUnsafeBytes { Data($0) }

    let second = KVCacheKEK(wrapper: wrapper, storage: storage)
    let kek2 = try await second.loadOrCreate()
    let raw2 = kek2.withUnsafeBytes { Data($0) }

    #expect(raw1 == raw2)
}

@Test
func kekWipeForcesRegeneration() async throws {
    let kek = testKEK()
    let first = try await kek.loadOrCreate()
    let raw1 = first.withUnsafeBytes { Data($0) }

    try await kek.wipe()
    #expect(try await kek.existsInStorage() == false)

    let second = try await kek.loadOrCreate()
    let raw2 = second.withUnsafeBytes { Data($0) }

    #expect(raw1 != raw2, "wipe must invalidate the cached KEK")
}

@Test
func kekDEKWrapUnwrapRoundtripWithAAD() async throws {
    let kek = testKEK()
    let aad = Data("model-hash=abc;tokens=1234".utf8)

    let (dek, wrapped) = try await kek.freshDEK(aad: aad)
    let raw1 = dek.withUnsafeBytes { Data($0) }

    let recovered = try await kek.unwrap(wrappedDEK: wrapped, aad: aad)
    let raw2 = recovered.withUnsafeBytes { Data($0) }

    #expect(raw1 == raw2)
}

@Test
func kekDEKUnwrapFailsOnTamperedAAD() async throws {
    let kek = testKEK()
    let aad = Data("trusted-metadata".utf8)
    let (_, wrapped) = try await kek.freshDEK(aad: aad)

    let tamperedAAD = Data("evil-metadata".utf8)
    await #expect(throws: KVCacheKEKError.self) {
        _ = try await kek.unwrap(wrappedDEK: wrapped, aad: tamperedAAD)
    }
}

@Test
func kekDEKUnwrapFailsOnTamperedCiphertext() async throws {
    let kek = testKEK()
    let aad = Data("metadata".utf8)
    var (_, wrapped) = try await kek.freshDEK(aad: aad)

    // Tag tamper.
    let last = wrapped.count - 1
    wrapped[last] ^= 0xFF
    await #expect(throws: KVCacheKEKError.self) {
        _ = try await kek.unwrap(wrappedDEK: wrapped, aad: aad)
    }
}

@Test
func kekFreshDEKProducesUniqueKeys() async throws {
    let kek = testKEK()
    let aad = Data("metadata".utf8)

    let (dek1, _) = try await kek.freshDEK(aad: aad)
    let (dek2, _) = try await kek.freshDEK(aad: aad)

    let raw1 = dek1.withUnsafeBytes { Data($0) }
    let raw2 = dek2.withUnsafeBytes { Data($0) }
    #expect(raw1 != raw2, "DEKs must be independently random per file")
}

@Test
func kekUnwrapFailsAfterStorageWipe() async throws {
    // Simulate Keychain wipe between writer and reader: same wrapper
    // (so unwrap of any prior wrap WOULD succeed in principle), but
    // the wrapped KEK isn't in storage anymore — so loadOrCreate
    // generates a *new* KEK, and the old DEK won't unwrap under it.
    let wrapper = InMemoryKeyWrappingService()
    let storage = InMemoryWrappedKEKStorage(identifier: "wipe")

    let kek = KVCacheKEK(wrapper: wrapper, storage: storage)
    let aad = Data("aad".utf8)
    let (_, wrappedDEK) = try await kek.freshDEK(aad: aad)

    try await kek.wipe()

    // New KEK actor, same wrapper/storage. KEK is regenerated.
    let fresh = KVCacheKEK(wrapper: wrapper, storage: storage)
    await #expect(throws: KVCacheKEKError.self) {
        _ = try await fresh.unwrap(wrappedDEK: wrappedDEK, aad: aad)
    }
}

// MARK: - Secure Enclave + Keychain end-to-end (skips when unavailable)

@Test
func kekRoundtripsViaSecureEnclave() async throws {
    guard PersistentEnclaveKey.isAvailable else {
        print("Skipping SE-backed KEK test: Secure Enclave not available")
        return
    }

    let testLabel = "io.darkbloom.kv.kek-test.\(UUID().uuidString)"
    let seKey: PersistentEnclaveKey
    do {
        seKey = try PersistentEnclaveKey.loadOrCreate(label: testLabel)
    } catch let e as PersistentEnclaveKeyError {
        if case .missingEntitlement = e {
            print("Skipping SE-backed KEK test: missing keychain-access-groups entitlement")
            return
        }
        throw e
    }
    defer { try? PersistentEnclaveKey.delete(label: testLabel) }

    let svc = SecureEnclaveKeyWrappingService(enclaveKey: seKey)
    let storage = InMemoryWrappedKEKStorage(identifier: "se-roundtrip")
    let kek = KVCacheKEK(wrapper: svc, storage: storage)

    let first = try await kek.loadOrCreate()
    let second = try await kek.loadOrCreate()
    #expect(
        first.withUnsafeBytes { Data($0) } == second.withUnsafeBytes { Data($0) },
        "SE-backed KEK must be idempotent within a process"
    )

    let aad = Data("se-test-metadata".utf8)
    let (dek, wrapped) = try await kek.freshDEK(aad: aad)
    let recovered = try await kek.unwrap(wrappedDEK: wrapped, aad: aad)
    #expect(
        dek.withUnsafeBytes { Data($0) } == recovered.withUnsafeBytes { Data($0) }
    )
}

@Test
func kekRoundtripsViaKeychainStorage() async throws {
    // Exercise the real Keychain storage path with an in-memory
    // wrapper. Skips on missing entitlement, same as the SE test.
    //
    // Probe with `save()` rather than `load()`: in unsigned test
    // builds `SecItemCopyMatching` returns errSecItemNotFound
    // (which we treat as "no entry yet" → nil), while
    // `SecItemAdd` is what surfaces -34018. So a read-only probe
    // can succeed even when writes would fail.
    let service = "io.darkbloom.kv.kek-storage-test.\(UUID().uuidString)"
    let storage = KeychainWrappedKEKStorage(service: service, account: "t")

    do {
        try storage.save(Data([0x01]))
        try? storage.delete()
    } catch WrappedKEKStorageError.missingEntitlement {
        print("Skipping Keychain storage test: missing keychain-access-groups entitlement")
        return
    } catch {
        throw error
    }

    let wrapper = InMemoryKeyWrappingService()
    let kek = KVCacheKEK(wrapper: wrapper, storage: storage)
    defer { try? storage.delete() }

    let first = try await kek.loadOrCreate()
    let raw1 = first.withUnsafeBytes { Data($0) }

    // Fresh actor, same storage = simulated restart.
    let kek2 = KVCacheKEK(wrapper: wrapper, storage: storage)
    let second = try await kek2.loadOrCreate()
    let raw2 = second.withUnsafeBytes { Data($0) }

    #expect(raw1 == raw2)
    try await kek2.wipe()
}

// MARK: - first-use KEK race (saveIfAbsent first-writer-wins)

@Test
func kekConcurrentFirstUseAdoptsSingleKEK() async throws {
    // Two KVCacheKEK instances sharing the SAME
    // storage (e.g. two model loads on a fresh machine) must converge on ONE
    // KEK. Before the fix, loadOrCreate used a clobbering save(): both generated
    // different KEKs and the later overwrote the earlier, stranding files the
    // earlier owner had written. After the fix, save goes through saveIfAbsent
    // (atomic create-if-absent): the first writer wins and the second ADOPTS it.
    // Revert-guard: switch loadOrCreate back to storage.save() and the two KEKs
    // diverge → this test fails.
    let wrapper = InMemoryKeyWrappingService()  // shared so both can unwrap
    let storage = InMemoryWrappedKEKStorage(identifier: UUID().uuidString)
    let kekA = KVCacheKEK(wrapper: wrapper, storage: storage)
    let kekB = KVCacheKEK(wrapper: wrapper, storage: storage)

    // Both create concurrently against empty storage.
    async let a = kekA.loadOrCreate()
    async let b = kekB.loadOrCreate()
    let rawA = try await a.withUnsafeBytes { Data($0) }
    let rawB = try await b.withUnsafeBytes { Data($0) }

    #expect(rawA == rawB,
        "Concurrent first-use must converge on a single KEK (first writer wins, loser adopts)")

    // And it matches what actually persisted (the winner), so files written by
    // either instance decrypt after a restart.
    let persisted = try #require(try storage.load())
    let unwrapped = try wrapper.unwrap(persisted)
    #expect(unwrapped == rawA, "the persisted KEK must equal the adopted in-memory KEK")
}

@Test
func saveIfAbsentDoesNotOverwriteExisting() async throws {
    // Unit-level guarantee for the storage primitive: saveIfAbsent never clobbers
    // an existing entry and returns the pre-existing bytes.
    let storage = InMemoryWrappedKEKStorage(identifier: UUID().uuidString)
    let first = Data([0x01, 0x02, 0x03])
    let second = Data([0xAA, 0xBB, 0xCC])

    let r1 = try storage.saveIfAbsent(first)
    #expect(r1 == first, "first saveIfAbsent persists and returns its own bytes")

    let r2 = try storage.saveIfAbsent(second)
    #expect(r2 == first, "second saveIfAbsent must return the EXISTING bytes, not overwrite")
    #expect(try storage.load() == first, "storage must still hold the first writer's bytes")
}
