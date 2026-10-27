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

private let logger = Logger(subsystem: BuildEnvironment.current.serviceLogSubsystem, category: "kv-cache-kek")

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

    /// Serializes replacement of an unusable entry across every instance in
    /// the process: each model load builds its own `KVCacheKEK`, and they
    /// must converge on one replacement.
    private static let replacementLock = NSLock()

    /// A persisted entry that no retry can open: it does not authenticate
    /// under the current wrapping key, or it does not hold a 32-byte key.
    private struct UnusableEntry: Error {
        let detail: String
    }

    // MARK: Init

    public init(wrapper: KeyWrappingService, storage: WrappedKEKStorage) {
        self.wrapper = wrapper
        self.storage = storage
    }

    // MARK: Public API

    /// Return the unwrapped KEK, generating + persisting a new one on
    /// first call, or in place of an entry no wrapping key can open again.
    /// Subsequent calls return the cached in-memory key.
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
            let key: SymmetricKey
            do {
                key = try unwrapPersisted(wrapped)
                logger.info(
                    "Loaded existing KV cache KEK (wrapper=\(self.wrapper.identifier, privacy: .public), storage=\(self.storage.identifier, privacy: .public))"
                )
            } catch let unusable as UnusableEntry {
                key = try replaceUnusable(wrapped, cause: unusable)
            }
            loadedKEK = key
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

    /// Backend failures (a locked keychain, an unavailable Secure Enclave)
    /// are reported unchanged; only an entry that can never open is
    /// `UnusableEntry`.
    private func unwrapPersisted(_ wrapped: Data) throws -> SymmetricKey {
        let raw: Data
        do {
            raw = try wrapper.unwrap(wrapped)
        } catch KeyWrappingError.authenticationFailed(let detail),
            KeyWrappingError.invalidCiphertext(let detail)
        {
            throw UnusableEntry(detail: detail)
        } catch {
            throw KVCacheKEKError.unwrappingFailed(String(describing: error))
        }
        guard raw.count == 32 else {
            throw UnusableEntry(detail: "expected 32-byte KEK, got \(raw.count) bytes")
        }
        return SymmetricKey(data: raw)
    }

    /// An entry sealed to a Secure Enclave identity that no longer exists
    /// (the attestation key's self-repair re-mints it; `darkbloom unenroll`
    /// deletes it) never opens again, and every file it protected is already
    /// unreadable. Keeping it would refuse every SSD store on this Mac until
    /// someone deleted the Keychain item, so it is replaced by a fresh KEK
    /// sealed to the current identity. The stores' key-fingerprint binding
    /// then wipes the unreadable files on their next initialization.
    private func replaceUnusable(_ unusable: Data, cause: UnusableEntry) throws -> SymmetricKey {
        try Self.replacementLock.withLock {
            let current: Data?
            do {
                current = try storage.load()
            } catch {
                throw KVCacheKEKError.storageError(String(describing: error))
            }
            if let current, current != unusable {
                // Another loader in this process replaced it first.
                do {
                    return try unwrapPersisted(current)
                } catch let other as UnusableEntry {
                    throw KVCacheKEKError.unwrappingFailed(other.detail)
                }
            }
            let fresh = SymmetricKey(size: .bits256)
            let wrapped: Data
            do {
                wrapped = try wrapper.wrap(fresh.withUnsafeBytes { Data($0) })
            } catch {
                throw KVCacheKEKError.wrappingFailed(String(describing: error))
            }
            do {
                try storage.save(wrapped)
            } catch {
                throw KVCacheKEKError.storageError(String(describing: error))
            }
            logger.warning(
                "Replaced an unusable KV cache KEK (\(cause.detail, privacy: .public)); SSD prefix-cache files written under it are unreadable and are removed when each cache next starts (wrapper=\(self.wrapper.identifier, privacy: .public), storage=\(self.storage.identifier, privacy: .public))"
            )
            return fresh
        }
    }
}
