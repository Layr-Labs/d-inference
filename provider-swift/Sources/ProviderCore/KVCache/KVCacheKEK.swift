/// KVCacheKEK — the key-encrypting key for the on-disk KV cache.
///
/// One KEK per provider, lifetime = provider lifetime. At rest it
/// lives behind a `WrappedKEKStorage` (Keychain in production,
/// in-memory in tests) wrapped by a `KeyWrappingService` (ECIES
/// against the persistent SE identity in production, AES-GCM under
/// a process-local key in tests). At runtime, after first unwrap,
/// the KEK is held in memory inside this actor.
///
/// Public surface: `loadOrCreate()` → unwrapped `SymmetricKey`. Idempotent.
/// The SSD prefix-cache tier (`KVCacheSSD/`) wraps its per-file DEKs under
/// the returned key.
///
/// Threading: actor. The loaded KEK lives in actor-isolated state.

import CryptoKit
import Foundation
import os

private let logger = Logger(subsystem: "dev.darkbloom.provider", category: "kv-cache-kek")

// MARK: - Errors

public enum KVCacheKEKError: Error, CustomStringConvertible, Sendable {
    case storageError(String)
    case wrappingFailed(String)
    case unwrappingFailed(String)

    public var description: String {
        switch self {
        case .storageError(let m): return "wrapped KEK storage: \(m)"
        case .wrappingFailed(let m): return "KEK wrap failed: \(m)"
        case .unwrappingFailed(let m): return "KEK unwrap failed: \(m)"
        }
    }
}

// MARK: - Actor

public actor KVCacheKEK {

    // MARK: State

    private let wrapper: KeyWrappingService
    private let storage: WrappedKEKStorage

    /// Non-nil after first successful `loadOrCreate()`. Holds the raw
    /// 32-byte KEK so subsequent calls don't pay the unwrap cost.
    private var loadedKEK: SymmetricKey?

    // MARK: Init

    public init(wrapper: KeyWrappingService, storage: WrappedKEKStorage) {
        self.wrapper = wrapper
        self.storage = storage
    }

    // MARK: Public API

    /// Return the unwrapped KEK, generating + persisting a new one on
    /// first call. Subsequent calls return the cached in-memory key.
    @discardableResult
    public func loadOrCreate() throws -> SymmetricKey {
        if let cached = loadedKEK {
            return cached
        }

        let existing: Data?
        do {
            existing = try storage.load()
        } catch {
            throw KVCacheKEKError.storageError(String(describing: error))
        }

        if let wrapped = existing {
            let raw: Data
            do {
                raw = try wrapper.unwrap(wrapped)
            } catch {
                throw KVCacheKEKError.unwrappingFailed(String(describing: error))
            }
            guard raw.count == 32 else {
                throw KVCacheKEKError.unwrappingFailed(
                    "expected 32-byte KEK, got \(raw.count) bytes — storage entry may be corrupt"
                )
            }
            let key = SymmetricKey(data: raw)
            loadedKEK = key
            logger.info(
                "Loaded existing KV cache KEK (wrapper=\(self.wrapper.identifier, privacy: .public), storage=\(self.storage.identifier, privacy: .public))"
            )
            return key
        }

        // First boot — generate, wrap, persist.
        let newKEK = SymmetricKey(size: .bits256)
        let raw = newKEK.withUnsafeBytes { Data($0) }

        let wrapped: Data
        do {
            wrapped = try wrapper.wrap(raw)
        } catch {
            throw KVCacheKEKError.wrappingFailed(String(describing: error))
        }
        // Atomic create-if-absent, NOT a clobbering save. If a
        // concurrent first-use (another model load on a fresh machine) already
        // persisted a different KEK, `saveIfAbsent` returns THAT one and we adopt
        // it — so every cache file in the process is governed by a single KEK
        // instead of the loser stranding files under an overwritten key.
        let authoritative: Data
        do {
            authoritative = try storage.saveIfAbsent(wrapped)
        } catch {
            throw KVCacheKEKError.storageError(String(describing: error))
        }
        if authoritative == wrapped {
            loadedKEK = newKEK
            logger.info(
                "Generated and persisted new KV cache KEK (wrapper=\(self.wrapper.identifier, privacy: .public), storage=\(self.storage.identifier, privacy: .public))"
            )
            return newKEK
        }
        // We lost the create race; adopt the winner by unwrapping its bytes.
        let adopted: Data
        do {
            adopted = try wrapper.unwrap(authoritative)
        } catch {
            throw KVCacheKEKError.unwrappingFailed(String(describing: error))
        }
        guard adopted.count == 32 else {
            throw KVCacheKEKError.unwrappingFailed(
                "expected 32-byte KEK, got \(adopted.count) bytes — storage entry may be corrupt"
            )
        }
        let key = SymmetricKey(data: adopted)
        loadedKEK = key
        logger.info(
            "Adopted existing KV cache KEK after concurrent first-use (wrapper=\(self.wrapper.identifier, privacy: .public), storage=\(self.storage.identifier, privacy: .public))"
        )
        return key
    }
}
