import Foundation
import DarkbloomClusterSecurity

extension ClusterKeychainEdgeSecretVault {
    /// The signed app's Keychain access group, the Secure Enclave key's (`PersistentEnclaveKey.defaultAccessGroup`);
    /// `DARKBLOOM_KEYCHAIN_ACCESS_GROUP` overrides both.
    static let appAccessGroup = "SLDQ2GJ6TL.io.darkbloom.provider"

    /// This install's edge secrets: a service under the install's keychain prefix
    /// (`io.darkbloom.cluster-pairing.edge-secret`, DevNet's `io.darkbloom.dev.…`), so two installs on one Mac never
    /// share an item, in the app's access group, which the signed CLI and its LaunchAgents share.
    static func install(environment: BuildEnvironment = .current,
                        processEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> ClusterKeychainEdgeSecretVault {
        let group = processEnvironment["DARKBLOOM_KEYCHAIN_ACCESS_GROUP"].flatMap { $0.isEmpty ? nil : $0 } ?? appAccessGroup
        return ClusterKeychainEdgeSecretVault(service: environment.keychainServicePrefix + ".cluster-pairing.edge-secret",
                                              accessGroup: group)
    }
}

/// The secret a saved setup's link control attachment names (`linkControl.secretFile`).
///
/// A setup made from a pairing names that pairing's `edge-<pin>.secret` in this install's pairing store, as the pairing
/// records it (`ClusterPairingRecord.Link.secretFile`): its secret is read through that store, from this Mac's Keychain
/// (0.10.12's file is moved in on first use). Any other file (the local qualification's, fixtures) is still one hex
/// line in a private file of this user.
enum DistributedInstalledLinkSecret {
    /// What a start says when the pairing a setup names is gone, or its key is.
    static let unpaired = "Run `darkbloom cluster` on both Macs; it pairs again by itself. (The link key of this Mac's pairing is gone: the Macs were unpaired.)"
    /// What a start says while this Mac's Keychain is locked (a restart, and no login since).
    static let locked = "Log in to this Mac once since it started (at its screen or with Screen Sharing); the pair then starts by itself. (This Mac's link key is in its Keychain, which stays locked after a restart until someone logs in.)"

    /// This install's pairing store, as `ClusterPairingStore.default()` opens it.
    static var installPairingDirectory: URL {
        ClusterUserPaths.pairingDirectory(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// The pairing whose secret `path` names, in the store at `pairingDirectory` read with `vault`; nil when `path`
    /// names no pairing's secret there.
    static func pairing(naming path: String, pairingDirectory: URL,
                        vault: (any ClusterEdgeSecretVault)?) throws -> (store: ClusterPairingStore, record: ClusterPairingRecord)? {
        guard ClusterLinkControlAttachment.namesPairingSecret(path, in: pairingDirectory) else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let store = ClusterPairingStore(directory: pairingDirectory, vault: vault)
        let records: ClusterPairingRecords?
        do { records = try store.load() } catch {
            throw ClusterConfigurationError.invalid("This Mac's pairing record couldn't be read (\(error))")
        }
        guard let record = records?.pairings.first(where: { URL(fileURLWithPath: $0.link.secretFile).standardizedFileURL == url }) else {
            throw ClusterConfigurationError.invalid(unpaired)
        }
        return (store, record)
    }

    /// The 32 or more secret bytes `path` names; never printed.
    static func read(_ path: String, pairingDirectory: URL = installPairingDirectory,
                     vault: (any ClusterEdgeSecretVault)? = ClusterKeychainEdgeSecretVault.install()) throws -> Data {
        guard case let (store, record)? = try pairing(naming: path, pairingDirectory: pairingDirectory, vault: vault) else {
            return try DistributedInstalledLinkEdge.readSecret(URL(fileURLWithPath: path))
        }
        do { return try store.edgeSecret(for: record) } catch { throw refusal(error) }
    }

    /// A start's check that the pairing `path` names still holds its key (in the Keychain, or 0.10.12's private file
    /// not moved yet), without reading it. False when `path` names no pairing's secret (the caller checks the file).
    static func requirePresent(_ path: String, pairingDirectory: URL = installPairingDirectory,
                               vault: (any ClusterEdgeSecretVault)? = ClusterKeychainEdgeSecretVault.install()) throws -> Bool {
        guard case let (store, record)? = try pairing(naming: path, pairingDirectory: pairingDirectory, vault: vault) else { return false }
        switch store.linkKeyLocation(for: record) {
        case .keychain: return true
        case .file: try ClusterConfigurationFiles.credentialMetadata(URL(fileURLWithPath: path), privateMode: true); return true
        case .missing: throw ClusterConfigurationError.invalid(unpaired)
        case .keychainLocked: throw ClusterConfigurationError.invalid(locked)
        case .keychainUnavailable(let status): throw refusal(ClusterPairingStoreError.keychainUnavailable(status))
        }
    }

    private static func refusal(_ error: Error) -> Error {
        switch error as? ClusterPairingStoreError {
        case .linkKeyMissing?: return ClusterConfigurationError.invalid(unpaired)
        case .keychainLocked?: return ClusterConfigurationError.invalid(locked)
        case let error?: return ClusterConfigurationError.invalid("This Mac's link key couldn't be read (\(error))")
        case nil: return error
        }
    }
}
