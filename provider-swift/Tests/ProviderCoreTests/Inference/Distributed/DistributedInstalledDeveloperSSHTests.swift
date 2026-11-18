import Foundation
import Testing
@testable import ProviderCore

/// The developer SSH switch is a developer and test harness only: a release
/// build (CI compiles the tests as one) ignores it, so a setup that reaches the
/// follower over SSH is refused there whatever the environment says.
@Suite struct DistributedInstalledDeveloperSSHTests {
    private static let switchOn = [DistributedInstalledDeveloperSSH.environmentKey: "1"]

    static func sshSetup() throws -> ClusterConfiguration {
        let pin = String(repeating: "a", count: 64)
        let object: [String: Any] = [
            "schema": ClusterConfiguration.schemaName, "clusterID": "fixture", "memberID": "mac-a", "role": "leader",
            "publicModelID": "fixture/model", "capabilitySHA256": pin, "selectedPlanSHA256": pin,
            "chunkTokens": 512, "requestTimeoutSeconds": 60, "peers": [Any](),
            "coordinator": ["address": "127.0.0.1", "port": 1],
            "trust": ["identityFile": "/Users/fixture/id", "knownHostsFile": "/Users/fixture/known_hosts", "knownHostsSHA256": pin],
            "tokenizerFiles": [Any](),
        ]
        let setup = try JSONDecoder().decode(ClusterConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        try #require(setup.trust != nil && setup.linkControl == nil)
        return setup
    }

    @Test("a release build ignores the developer SSH switch and refuses an SSH setup")
    func releaseBuildIgnoresTheSwitch() throws {
        guard BuildEnvironment.current == .prod else { return }
        let setup = try Self.sshSetup()
        #expect(!DistributedInstalledDeveloperSSH.enabled(Self.switchOn))
        #expect(throws: (any Error).self) {
            try DistributedInstalledDeveloperSSH.requireFollowerRoute(setup, environment: Self.switchOn)
        }
    }
}
