// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation

/// The two-Mac prefix cache's SSD key on a build that holds the product's
/// keychain entitlement: derived (HKDF-SHA256, its own label) from the same
/// Secure Enclave-rooted KEK the single-Mac SSD tier uses, so records survive
/// owner, provider and machine restarts with no new keychain item and no new
/// permission. Never an ephemeral key: when the KEK is unavailable (a build
/// without the entitlement) this yields nil and the installed owner falls back
/// to its owner-only key file (`DistributedInstalledPrefixSSD`).
public enum ClusterPrefixSSDKeyMaterial {
    static let salt = Data("darkbloom-cluster-prefix-ssd-v1".utf8)

    /// Installs the derived key as the installed owner's key source. Called
    /// once by the `cluster worker-owner` command before it serves.
    public static func installAsOwnerKeySource() {
        DistributedInstalledPrefixSSD.installDurableKeySource { load() }
    }

    static func derive(from kek: SymmetricKey) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: kek, salt: salt, info: Data("owner-key".utf8), outputByteCount: 32)
            .withUnsafeBytes { Data($0) }
    }

    /// Blocking and bounded (the owner's entry is synchronous); nil when the
    /// KEK cannot be loaded in time.
    static func load(timeoutSeconds: Double = 5,
                     loader: @escaping @Sendable () async throws -> SymmetricKey = {
                         // No ephemeral key: an empty environment allows only the persistent KEK.
                         try await SSDCacheKeyMaterial.load(environment: [:]).key
                     }) -> Data? {
        let result = ResultBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            result.set((try? await loader()).map(derive(from:)))
            done.signal()
        }
        guard done.wait(timeout: .now() + timeoutSeconds) == .success else { return nil }
        return result.value
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Data?
        func set(_ value: Data?) { lock.lock(); stored = value; lock.unlock() }
        var value: Data? { lock.lock(); defer { lock.unlock() }; return stored }
    }
}
