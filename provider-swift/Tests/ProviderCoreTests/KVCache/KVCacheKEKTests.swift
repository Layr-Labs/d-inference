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
    let storage = InMemoryWrappedKEKStorage(identifier: UUID().uuidString)
    let kek = testKEK(storage: storage)

    #expect(try storage.load() == nil)

    let first = try await kek.loadOrCreate()

    #expect(try storage.load() != nil)

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

    // A fresh actor over the same storage unwraps the persisted KEK through
    // the Secure Enclave (simulated restart).
    let restarted = try await KVCacheKEK(wrapper: svc, storage: storage).loadOrCreate()
    #expect(
        first.withUnsafeBytes { Data($0) } == restarted.withUnsafeBytes { Data($0) }
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

// MARK: - an entry no wrapping key can open again

/// A wrapper whose unwrap always fails in the backend, the way a locked
/// keychain or an unavailable Secure Enclave does.
private final class UnavailableUnwrapService: KeyWrappingService, @unchecked Sendable {
    let identifier = "backend-unavailable"
    func wrap(_ plaintext: Data) throws -> Data { plaintext }
    func unwrap(_ wrapped: Data) throws -> Data {
        throw KeyWrappingError.backendError("errSecInteractionNotAllowed")
    }
}

@Test
func kekReplacesAnEntrySealedToAReplacedIdentity() async throws {
    // The Secure Enclave identity that sealed the entry was re-minted: the
    // same storage, a different wrapping key.
    let storage = InMemoryWrappedKEKStorage(identifier: UUID().uuidString)
    let original = InMemoryKeyWrappingService(key: SymmetricKey(size: .bits256), identifier: "before")
    let stranded = try await KVCacheKEK(wrapper: original, storage: storage).loadOrCreate()
    let strandedEntry = try #require(try storage.load())

    let current = InMemoryKeyWrappingService(key: SymmetricKey(size: .bits256), identifier: "after")
    let replaced = try await KVCacheKEK(wrapper: current, storage: storage).loadOrCreate()
    let raw = replaced.withUnsafeBytes { Data($0) }
    #expect(raw != stranded.withUnsafeBytes { Data($0) })
    let entry = try #require(try storage.load())
    #expect(entry != strandedEntry)
    #expect(try current.unwrap(entry) == raw, "the replacement is sealed to the current identity")

    // Simulated restart: the replacement persists and is not replaced again.
    let restarted = try await KVCacheKEK(wrapper: current, storage: storage).loadOrCreate()
    #expect(restarted.withUnsafeBytes { Data($0) } == raw)
    #expect(try storage.load() == entry)
}

@Test
func kekReplacesACorruptEntry() async throws {
    let wrapper = InMemoryKeyWrappingService()
    for corrupt in [Data([0x01, 0x02]), try wrapper.wrap(Data(repeating: 7, count: 16))] {
        let storage = InMemoryWrappedKEKStorage(identifier: UUID().uuidString, initial: corrupt)
        let key = try await KVCacheKEK(wrapper: wrapper, storage: storage).loadOrCreate()
        let entry = try #require(try storage.load())
        #expect(entry != corrupt)
        #expect(try wrapper.unwrap(entry) == key.withUnsafeBytes { Data($0) })
    }
}

@Test
func kekKeepsTheEntryWhenTheBackendCannotUnwrap() async throws {
    // A backend failure says nothing about the entry: report it and keep it.
    let entry = Data(repeating: 0xAB, count: 60)
    let storage = InMemoryWrappedKEKStorage(identifier: UUID().uuidString, initial: entry)
    let kek = KVCacheKEK(wrapper: UnavailableUnwrapService(), storage: storage)
    await #expect(throws: KVCacheKEKError.self) { try await kek.loadOrCreate() }
    #expect(try storage.load() == entry)
}

@Test
func concurrentLoadersConvergeOnOneReplacement() async throws {
    let storage = InMemoryWrappedKEKStorage(identifier: UUID().uuidString)
    _ = try await KVCacheKEK(wrapper: InMemoryKeyWrappingService(), storage: storage).loadOrCreate()
    let current = InMemoryKeyWrappingService()
    let loaders = (0..<6).map { _ in KVCacheKEK(wrapper: current, storage: storage) }
    let keys = try await withThrowingTaskGroup(of: Data.self) { group in
        for loader in loaders {
            group.addTask { try await loader.loadOrCreate().withUnsafeBytes { Data($0) } }
        }
        return try await group.reduce(into: Set<Data>()) { _ = $0.insert($1) }
    }
    #expect(keys.count == 1, "every loader must adopt the single replacement")
    let entry = try #require(try storage.load())
    #expect(try keys.first == current.unwrap(entry))
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
