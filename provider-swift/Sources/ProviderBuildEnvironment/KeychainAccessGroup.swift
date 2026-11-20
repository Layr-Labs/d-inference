import Foundation

/// The keychain access group of the Secure Enclave key, the SSD cache key and
/// the pairing's link keys (`PersistentEnclaveKey`,
/// `ClusterKeychainEdgeSecretVault.install`). A signed release holds one group,
/// `signedApp` (an entitlement, the same for every install: `BuildEnvironment`),
/// and always uses it; only a debug build (tests, development) reads
/// `environmentKey`.
public enum KeychainAccessGroup {
    public static let signedApp = "SLDQ2GJ6TL.io.darkbloom.provider"
    public static let environmentKey = "DARKBLOOM_KEYCHAIN_ACCESS_GROUP"

    /// Whether this build reads `environmentKey`.
    public static var readsEnvironmentInThisBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// `override`; else, where `readsEnvironment`, a non-empty
    /// `environmentKey`; else `signedApp`.
    public static func resolved(override: String? = nil,
                                environment: [String: String] = ProcessInfo.processInfo.environment,
                                readsEnvironment: Bool = readsEnvironmentInThisBuild) -> String {
        if let override { return override }
        if readsEnvironment, let group = environment[environmentKey], !group.isEmpty { return group }
        return signedApp
    }
}
