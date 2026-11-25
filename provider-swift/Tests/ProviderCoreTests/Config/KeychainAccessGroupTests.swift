import DarkbloomClusterSecurity
import Foundation
import Testing
@testable import ProviderCore

/// The keychain access group of the Secure Enclave key and the link keys: a
/// release build always uses the signed app's group; only a debug build reads
/// `DARKBLOOM_KEYCHAIN_ACCESS_GROUP`. No keychain item is read or written.
@Suite struct KeychainAccessGroupTests {
    static let other = "TEAMID0000.io.example"
    static let environment = [KeychainAccessGroup.environmentKey: other]

    @Test func releaseBuildsUseTheAppGroupWhateverTheEnvironment() {
        #expect(KeychainAccessGroup.resolved(environment: Self.environment, readsEnvironment: false)
                == KeychainAccessGroup.signedApp)
        #expect(PersistentEnclaveKey.defaultAccessGroup == KeychainAccessGroup.signedApp)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pairing-\(UUID().uuidString)")
        #expect(ClusterKeychainEdgeSecretVault.install(pairingDirectory: directory, environment: .prod,
                                                       processEnvironment: Self.environment, readsEnvironment: false).accessGroup
                == KeychainAccessGroup.signedApp, "the link keys use the same group")
    }

    @Test func debugBuildsReadTheEnvironment() {
        #expect(KeychainAccessGroup.resolved(environment: Self.environment, readsEnvironment: true) == Self.other)
        #expect(KeychainAccessGroup.resolved(environment: [KeychainAccessGroup.environmentKey: ""], readsEnvironment: true)
                == KeychainAccessGroup.signedApp)
    }

    @Test func anExplicitGroupWins() {
        for reads in [false, true] {
            #expect(KeychainAccessGroup.resolved(override: "TEAMID0001.io.test", environment: Self.environment,
                                                 readsEnvironment: reads) == "TEAMID0001.io.test")
        }
    }

    @Test func thisBuildReadsTheEnvironmentOnlyWhenItIsADebugBuild() {
        #if DEBUG
        #expect(KeychainAccessGroup.readsEnvironmentInThisBuild)
        #else
        #expect(!KeychainAccessGroup.readsEnvironmentInThisBuild)
        #endif
    }
}
