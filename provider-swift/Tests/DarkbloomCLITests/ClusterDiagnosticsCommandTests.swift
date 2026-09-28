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
