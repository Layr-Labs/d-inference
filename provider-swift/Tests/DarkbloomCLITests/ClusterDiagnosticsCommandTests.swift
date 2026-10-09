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

@Test func clusterLinkParsesOnlyItsOutputFormatAndIsRegistered() throws {
    let summary = try Cluster.Link.parse([])
    #expect(!summary.json)
    let report = try Cluster.Link.parse(["--json"])
    #expect(report.json)
    let dispatched = try Darkbloom.parseAsRoot(["cluster", "link", "--json"])
    #expect(dispatched is Cluster.Link)
    // The command reads local state only: nothing selects a host, a device, a file or a fix.
    for refused in [["--fix"], ["--enable"], ["--device", "rdma_en7"], ["--config", "/tmp/provider.toml"],
                    ["--host", "remote.example"]] {
        #expect(throws: (any Error).self) { _ = try Cluster.Link.parse(refused) }
    }
}
