import DarkbloomClusterSecurity
import Foundation
import Testing
@testable import ProviderCore

/// The keychain access group of the Secure Enclave key and the link keys: a
/// release build always uses the signed app's group; only a debug build reads
/// `DARKBLOOM_KEYCHAIN_ACCESS_GROUP`. No keychain item is read or written.
@Suite struct PersistentEnclaveKeyAccessGroupTests {
    static let other = "TEAMID0000.io.example"
    static let environment = [PersistentEnclaveKey.accessGroupEnvironmentKey: other]

    @Test func releaseBuildsUseTheAppGroupWhateverTheEnvironment() {
        #expect(PersistentEnclaveKey.resolvedAccessGroup(override: nil, environment: Self.environment, readsEnvironment: false)
                == PersistentEnclaveKey.defaultAccessGroup)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pairing-\(UUID().uuidString)")
        #expect(ClusterKeychainEdgeSecretVault.install(pairingDirectory: directory, environment: .prod,
                                                       processEnvironment: Self.environment, readsEnvironment: false).accessGroup
                == PersistentEnclaveKey.defaultAccessGroup, "the link keys use the same group")
    }

    @Test func debugBuildsReadTheEnvironment() {
        #expect(PersistentEnclaveKey.resolvedAccessGroup(override: nil, environment: Self.environment, readsEnvironment: true)
                == Self.other)
        #expect(PersistentEnclaveKey.resolvedAccessGroup(override: nil, environment: [PersistentEnclaveKey.accessGroupEnvironmentKey: ""],
                                                         readsEnvironment: true) == PersistentEnclaveKey.defaultAccessGroup)
    }

    @Test func anExplicitGroupWins() {
        for reads in [false, true] {
            #expect(PersistentEnclaveKey.resolvedAccessGroup(override: "TEAMID0001.io.test", environment: Self.environment,
                                                             readsEnvironment: reads) == "TEAMID0001.io.test")
        }
    }

    @Test func thisBuildReadsTheEnvironmentOnlyWhenItIsADebugBuild() {
        #if DEBUG
        #expect(PersistentEnclaveKey.readsAccessGroupFromEnvironment)
        #else
        #expect(!PersistentEnclaveKey.readsAccessGroupFromEnvironment)
        #endif
    }
}
