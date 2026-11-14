import DarkbloomClusterSecurity
import Foundation

extension ClusterPairingStore {
    /// This install's pairing store (`ClusterUserPaths.pairingDirectory`): production's `~/.darkbloom/cluster-pairing`,
    /// DevNet's `~/.darkbloom-dev/cluster-pairing`. Every command and service of a build opens its pairing here, so
    /// one app's pairing never decides the other's. Its edge secrets are in the data-protection Keychain under the
    /// install's own service (`ClusterKeychainEdgeSecretVault.install`); a build without the Keychain entitlement keeps
    /// 0.10.12's files.
    public static func `default`(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                 environment: BuildEnvironment = .current) -> ClusterPairingStore {
        ClusterPairingStore(directory: ClusterUserPaths.pairingDirectory(home: home, environment: environment),
                            vault: ClusterKeychainEdgeSecretVault.install(environment: environment))
    }
}
