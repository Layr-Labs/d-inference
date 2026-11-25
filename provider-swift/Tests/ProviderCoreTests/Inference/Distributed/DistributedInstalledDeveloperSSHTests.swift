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

    @Test("with build .prod the switch is ignored; with build .dev it still works")
    func switchFollowsTheBuild() throws {
        let setup = try Self.sshSetup()
        #expect(!DistributedInstalledDeveloperSSH.enabled(Self.switchOn, build: .prod))
        let refusal = #expect(throws: (any Error).self) {
            try DistributedInstalledDeveloperSSH.requireFollowerRoute(setup, environment: Self.switchOn, build: .prod)
        }
        let message = refusal.map { String(describing: $0) } ?? ""
        #expect(message.contains("over SSH") && message.contains("developer harness") && message.contains("only over the link"))
        #expect(!message.contains(DistributedInstalledDeveloperSSH.environmentKey))

        #expect(DistributedInstalledDeveloperSSH.enabled(Self.switchOn, build: .dev))
        #expect(!DistributedInstalledDeveloperSSH.enabled([DistributedInstalledDeveloperSSH.environmentKey: "yes"], build: .dev))
        try DistributedInstalledDeveloperSSH.requireFollowerRoute(setup, environment: Self.switchOn, build: .dev)
        #expect(throws: (any Error).self) {
            try DistributedInstalledDeveloperSSH.requireFollowerRoute(setup, environment: [:], build: .dev)
        }
    }

    @Test("a release build opens no SSH route to the other Mac, whatever the switch says")
    func releaseBuildOpensNoSSHRoute() throws {
        let refusal = #expect(throws: (any Error).self) { try DistributedInstalledDeveloperSSH.requireSSHRoute(build: .prod) }
        #expect((refusal.map { String(describing: $0) } ?? "").contains("only over the link"))
        try DistributedInstalledDeveloperSSH.requireSSHRoute(build: .dev)
        try DistributedInstalledDeveloperSSH.requireSSHRoute(build: .staging)

        // Planning asks the other Mac for its profile over the pair description's SSH route only outside a release build.
        let pin = String(repeating: "a", count: 64)
        func member(_ id: String, _ host: String) -> ClusterPairDescription.Member {
            ClusterPairDescription.Member(id: id, host: host, port: 22, user: "fixture",
                ownerExecutable: "/Users/fixture/darkbloom", workerExecutable: "/Users/fixture/darkbloom-cluster-worker",
                modelDirectory: "/Users/fixture/model", runtimeBinarySHA256: pin, jacclDevice: "en7", linkAddress: host,
                trust: .init(identityFile: "/Users/fixture/id", knownHostsFile: "/Users/fixture/known_hosts", knownHostsSHA256: pin))
        }
        let local = member("mac-a", "192.0.2.1"), peer = member("mac-b", "192.0.2.2")
        #expect(throws: (any Error).self) { _ = try ClusterPlacementFlow.peerProfileCommand(local: local, peer: peer, build: .prod) }
        if BuildEnvironment.current == .prod {
            #expect(throws: (any Error).self) { _ = try ClusterPlacementFlow.peerProfileCommand(local: local, peer: peer) }
        }
    }
}
