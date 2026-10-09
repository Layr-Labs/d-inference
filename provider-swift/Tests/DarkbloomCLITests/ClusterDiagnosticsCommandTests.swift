import Testing
import ArgumentParser
@testable import darkbloom

@Test func clusterDiagnosticsParseWithoutEnablingOrRecoveryFlags() throws {
    let status = try Cluster.Status.parse(["--json", "--config", "/tmp/provider.toml"])
    #expect(status.json && status.configOptions.config == "/tmp/provider.toml")
    let doctor = try Cluster.Doctor.parse(["--json"])
    #expect(doctor.json)
    #expect(throws: (any Error).self) { _ = try Cluster.Doctor.parse(["--fix"]) }
    #expect(throws: (any Error).self) { _ = try Cluster.Doctor.parse(["--physical"]) }
    #expect(throws: (any Error).self) { _ = try Cluster.Status.parse(["--enable"]) }
    #expect(throws: (any Error).self) { _ = try Cluster.Status.parse(["--host", "remote.example"]) }
}

@Test func clusterLinkParsesItsModesAndIsRegistered() throws {
    let summary = try Cluster.Link.parse([])
    #expect(!summary.json && !summary.fix && !summary.remove && !summary.watch && summary.device == nil)
    let report = try Cluster.Link.parse(["--json"])
    #expect(report.json)
    let dispatched = try Darkbloom.parseAsRoot(["cluster", "link", "--json"])
    #expect(dispatched is Cluster.Link)

    let fix = try Cluster.Link.parse(["--fix", "--device", "rdma_en6", "--json"])
    #expect(fix.fix && fix.device == "rdma_en6" && fix.json)
    let remove = try Cluster.Link.parse(["--remove"])
    #expect(remove.remove && remove.device == nil)
    let watch = try Cluster.Link.parse(["--watch", "--json"])
    #expect(watch.watch && watch.json)

    // One mode at a time, a device only where it applies, and nothing that
    // selects a host, a file, an address or a privileged command.
    for refused in [["--fix", "--remove"], ["--fix", "--watch"], ["--remove", "--watch"], ["--device", "rdma_en6"],
                    ["--watch", "--device", "rdma_en6"], ["--enable"], ["--config", "/tmp/provider.toml"],
                    ["--host", "remote.example"], ["--fix", "--address", "192.0.2.10"], ["--fix", "--sudo"]] {
        #expect(throws: (any Error).self) { _ = try Cluster.Link.parse(refused) }
    }
    // A device name is letters, digits and underscores: text that could alter
    // a command is refused before anything runs.
    for hostile in ["rdma_en6; id", "rdma_en6\"", "rdma_en6 inet 192.0.2.10", "$(id)", "-alias", "", "rdma_en6\nrdma_en7"] {
        #expect(throws: (any Error).self) { _ = try Cluster.Link.parse(["--fix", "--device", hostile]) }
        #expect(throws: (any Error).self) { _ = try Cluster.Link.parse(["--remove", "--device", hostile]) }
    }
}

@Test func bareClusterIsTheGuidedSetup() throws {
    let bare = try Darkbloom.parseAsRoot(["cluster"])
    #expect(bare is Cluster.Setup)
    let named = try Darkbloom.parseAsRoot(["cluster", "setup", "--json", "--yes"])
    let setup = try #require(named as? Cluster.Setup)
    #expect(setup.json && setup.yes)
    let flagged = try Darkbloom.parseAsRoot(["cluster", "--json"])
    let unattended = try #require(flagged as? Cluster.Setup)
    #expect(unattended.json && !unattended.yes)

    // The other cluster commands are reached exactly as before.
    let link = try Darkbloom.parseAsRoot(["cluster", "link"])
    #expect(link is Cluster.Link)
    let status = try Darkbloom.parseAsRoot(["cluster", "status"])
    #expect(status is Cluster.Status)
    let doctor = try Darkbloom.parseAsRoot(["cluster", "doctor"])
    #expect(doctor is Cluster.Doctor)

    // The flow chooses the port and the address itself: nothing can be passed in.
    for refused in [["--fix"], ["--device", "rdma_en6"], ["--address", "192.0.2.10"], ["--sudo"], ["--config", "/tmp/provider.toml"]] {
        #expect(throws: (any Error).self) { _ = try Cluster.Setup.parse(refused) }
    }
}
