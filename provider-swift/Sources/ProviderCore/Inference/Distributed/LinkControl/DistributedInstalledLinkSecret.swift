import CryptoKit
import Foundation
import DarkbloomClusterSecurity

extension ClusterKeychainEdgeSecretVault {
    /// The signed app's Keychain access group, the Secure Enclave key's (`PersistentEnclaveKey.defaultAccessGroup`);
    /// `DARKBLOOM_KEYCHAIN_ACCESS_GROUP` overrides both.
    static let appAccessGroup = "SLDQ2GJ6TL.io.darkbloom.provider"

    /// The edge secrets of the pairing store at `pairingDirectory`: a service under the install's keychain prefix
    /// (`io.darkbloom.cluster-pairing.edge-secret.<store>`, DevNet's `io.darkbloom.dev.…`) and the store's own path
    /// (`storeTag`), so neither two installs on one Mac nor two stores of one build (another home) share an item, in
    /// the app's access group, which the signed CLI and its LaunchAgents share.
    static func install(pairingDirectory: URL, environment: BuildEnvironment = .current,
                        processEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> ClusterKeychainEdgeSecretVault {
        let group = processEnvironment["DARKBLOOM_KEYCHAIN_ACCESS_GROUP"].flatMap { $0.isEmpty ? nil : $0 } ?? appAccessGroup
        return ClusterKeychainEdgeSecretVault(
            service: environment.keychainServicePrefix + ".cluster-pairing.edge-secret." + storeTag(pairingDirectory), accessGroup: group)
    }

    /// 12 hex digits of SHA-256 of the store's path (links resolved), the same for every caller that opens it.
    static func storeTag(_ pairingDirectory: URL) -> String {
        let path = pairingDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        return SHA256.hash(data: Data(path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
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
    static let locked = "Log in to this Mac once after its restart (at its screen or with Screen Sharing); the pair then starts by itself. (This Mac's link key is in its Keychain, which stays locked after a restart until someone logs in.)"

    /// This install's pairing store, as `ClusterPairingStore.default()` opens it.
    static var installPairingDirectory: URL {
        ClusterUserPaths.pairingDirectory(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// The vault each store is opened with (`ClusterKeychainEdgeSecretVault.install`); a stand-in in tests.
    typealias Vaults = @Sendable (_ pairingDirectory: URL) -> (any ClusterEdgeSecretVault)?
    static let installVaults: Vaults = { ClusterKeychainEdgeSecretVault.install(pairingDirectory: $0) }

    /// The pairing whose secret `path` names, in the store at `pairingDirectory`; nil when `path` names no pairing's
    /// secret there.
    static func pairing(naming path: String, pairingDirectory: URL,
                        vaults: Vaults) throws -> (store: ClusterPairingStore, record: ClusterPairingRecord)? {
        guard ClusterLinkControlAttachment.namesPairingSecret(path, in: pairingDirectory) else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let store = ClusterPairingStore(directory: pairingDirectory, vault: vaults(pairingDirectory))
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
    static func read(_ path: String, pairingDirectory: URL = installPairingDirectory, vaults: Vaults = installVaults) throws -> Data {
        guard case let (store, record)? = try pairing(naming: path, pairingDirectory: pairingDirectory, vaults: vaults) else {
            return try DistributedInstalledLinkEdge.readSecret(URL(fileURLWithPath: path))
        }
        do { return try store.edgeSecret(for: record) } catch { throw refusal(error) }
    }

    /// A start's check that the pairing `path` names still holds its key (in the Keychain, or 0.10.12's private file
    /// not moved yet), without reading it. False when `path` names no pairing's secret (the caller checks the file).
    static func requirePresent(_ path: String, pairingDirectory: URL = installPairingDirectory,
                               vaults: Vaults = installVaults) throws -> Bool {
        guard case let (store, record)? = try pairing(naming: path, pairingDirectory: pairingDirectory, vaults: vaults) else { return false }
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
