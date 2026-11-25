import DarkbloomClusterSecurity
import Foundation
import os

/// What a rollback leaves the release it restores of the cluster pairing's link keys (`ClusterPairingStore`): nothing
/// new. A release older than `firstKeychainRelease` (0.10.12 and earlier) reads them only from an `edge-<pin>.secret`
/// beside the pairing's records and links with the older link handshake, which no pair of this Mac speaks any more: the
/// updater writes it no key file, so such a release links with none of this Mac's pairs. The keys stay in the Keychain,
/// and a pair links again once both Macs run `firstKeychainRelease` or later. A release that keeps them in the Keychain
/// needs nothing either.
enum ClusterLinkKeyRollback {
    /// The first release that keeps link keys in the Keychain and links with link handshake v3 only. A change that
    /// ships in a later release moves this with it.
    static let firstKeychainRelease = "0.10.13"

    private static let log = Logger(subsystem: BuildEnvironment.current.serviceLogSubsystem, category: "cluster-link-key")

    /// Whether `version` reads link keys only from files (and links with the older handshake). A version that doesn't
    /// parse counts as one.
    static func restoresFileRelease(_ version: String) -> Bool {
        guard let restored = SemanticVersion(version), let first = SemanticVersion(firstKeychainRelease) else { return true }
        return restored < first
    }

    /// Says, for a rollback to `version` that reads link keys only from files, where each pairing's key stays: no key
    /// file is written for it. The pairing store beside the install's app (`installRoot`, the updater's;
    /// `ClusterUserPaths.pairingDirectory` for an installed app) is only read. Returns the lines it logged (no key
    /// material); none for a release that keeps keys in the Keychain.
    @discardableResult
    static func keep(installRoot: URL, restoring version: String, vault: (any ClusterEdgeSecretVault)?) -> [String] {
        guard restoresFileRelease(version) else { return [] }
        let store = ClusterPairingStore(directory: pairingDirectory(installRoot: installRoot), vault: vault)
        let lines = ((try? store.load())?.pairings ?? []).map { record in
            "the pairing with \(record.peerPin.prefix(16)): " + keyStays(store.linkKeyLocation(for: record))
                + "; no key file is written for v\(version), which links with an older handshake than \(firstKeychainRelease)"
                + " and so with no pair of this Mac"
        }
        for line in lines { log.info("rollback to v\(version, privacy: .public): \(line, privacy: .public)") }
        return lines
    }

    private static func keyStays(_ location: ClusterPairingStore.LinkKeyLocation) -> String {
        switch location {
        case .keychain: return "its link key stays in this Mac's Keychain for the next update"
        case .file: return "its link key is an earlier release's file, left as it is"
        case .missing: return "its link key is missing"
        case .keychainLocked: return "the Keychain is locked until someone logs in to this Mac"
        case .keychainUnavailable(let status): return "the Keychain did not answer (OSStatus \(status))"
        }
    }

    static func pairingDirectory(installRoot: URL) -> URL {
        installRoot.appendingPathComponent("cluster-pairing", isDirectory: true)
    }
}
