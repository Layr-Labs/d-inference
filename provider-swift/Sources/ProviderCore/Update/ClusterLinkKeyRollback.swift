import DarkbloomClusterSecurity
import Foundation
import os

/// What a rollback leaves the release it restores of the cluster pairing's link keys (`ClusterPairingStore`). A release
/// older than `firstKeychainRelease` (0.10.12 and earlier) reads them only from the `edge-<pin>.secret` beside the
/// pairing's records, so the updater writes them back from the Keychain when it restores one
/// (`UpdateRecoveryStore.rollback`, `recoverInterruptedTransaction`). A release that keeps them in the Keychain needs
/// nothing, and no file is written for it.
enum ClusterLinkKeyRollback {
    /// The first release that keeps link keys in the Keychain. A change that ships in a later release moves this with it.
    static let firstKeychainRelease = "0.10.13"

    private static let log = Logger(subsystem: BuildEnvironment.current.serviceLogSubsystem, category: "cluster-link-key")

    /// Whether `version` reads link keys only from files. A version that doesn't parse counts as one: a file written
    /// for a release that keeps keys in the Keychain is removed again by its next process.
    static func restoresFileRelease(_ version: String) -> Bool {
        guard let restored = SemanticVersion(version), let first = SemanticVersion(firstKeychainRelease) else { return true }
        return restored < first
    }

    /// Writes the keys back for `version` into the pairing store beside the install's app (`installRoot`, the
    /// updater's; `ClusterUserPaths.pairingDirectory` for an installed app) when that release reads only files.
    /// `rewrite`: once the rollback is done, a new file for every pairing, newer than every process running then.
    /// Returns the lines it logged (no key material).
    @discardableResult
    static func keep(installRoot: URL, restoring version: String, rewrite: Bool,
                     vault: (any ClusterEdgeSecretVault)?) -> [String] {
        guard restoresFileRelease(version) else { return [] }
        let lines = ClusterPairingStore(directory: pairingDirectory(installRoot: installRoot), vault: vault)
            .writeLegacyFilesForRollback(rewrite: rewrite)
        for line in lines { log.info("rollback to v\(version, privacy: .public): \(line, privacy: .public)") }
        return lines
    }

    static func pairingDirectory(installRoot: URL) -> URL {
        installRoot.appendingPathComponent("cluster-pairing", isDirectory: true)
    }
}
