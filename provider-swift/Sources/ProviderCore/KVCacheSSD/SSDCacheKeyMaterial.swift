// Copyright © 2026 Eigen Labs.

import CryptoKit

/// Shared key hierarchy for both encrypted SSD payload layouts. A test-only
/// ephemeral key is never persisted and cannot supply restart warmth.
struct SSDCacheKeyMaterial {
    let key: SymmetricKey
    let ephemeral: Bool

    enum Failure: Error {
        case persistentKeyUnavailable(any Error)
        case ephemeralKeyUnavailable
    }

    typealias PersistentLoader = @Sendable (SSDPersistentTestKeyNamespace?) async throws -> SymmetricKey

    static func load(
        environment: [String: String],
        persistentTestNamespace: SSDPersistentTestKeyNamespace? = nil,
        persistentLoader: PersistentLoader? = nil
    ) async throws -> Self {
        try persistentTestNamespace?.validate(environment: environment)
        let allowEphemeral = SSDPrefixCacheFactory.ephemeralAllowed(environment: environment)
        let forceEphemeral = SSDPrefixCacheFactory.forceEphemeralKey(environment: environment)
        if !forceEphemeral {
            do {
                let loadPersistent = persistentLoader ?? loadPersistentKey
                let key = try await loadPersistent(persistentTestNamespace)
                return Self(key: key, ephemeral: false)
            } catch {
                guard allowEphemeral, persistentTestNamespace == nil else {
                    throw Failure.persistentKeyUnavailable(error)
                }
            }
        }
        let kek = KVCacheKEK(
            wrapper: InMemoryKeyWrappingService(),
            storage: InMemoryWrappedKEKStorage(identifier: "ephemeral-ssd"))
        guard let key = try? await kek.loadOrCreate() else { throw Failure.ephemeralKeyUnavailable }
        return Self(key: key, ephemeral: true)
    }

    private static func loadPersistentKey(_ namespace: SSDPersistentTestKeyNamespace?) async throws -> SymmetricKey {
        // A custom label bypasses default-label migration. Do not use the
        // verified-load repair path, which may delete/recreate a key.
        let enclave = try PersistentEnclaveKey.loadOrCreate(
            accessGroup: namespace?.accessGroup, label: namespace?.enclaveLabel)
        let kek = KVCacheKEK(
            wrapper: SecureEnclaveKeyWrappingService(enclaveKey: enclave),
            storage: KeychainWrappedKEKStorage(
                service: namespace?.wrappedKEKService ?? KeychainWrappedKEKStorage.defaultService,
                account: namespace?.wrappedKEKAccount ?? KeychainWrappedKEKStorage.defaultAccount))
        return try await kek.loadOrCreate()
    }
}
