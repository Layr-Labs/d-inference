import Foundation
import ProviderCore
import Testing

@testable import darkbloom

@Suite("Doctor cluster checks")
struct DoctorClusterChecksTests {
    @Test("a Mac that is not paired gets no cluster checks and its link is not inspected")
    func unpairedMacGetsNone() async {
        let checks = await buildClusterDoctorChecks(configPath: "/nonexistent/provider.toml", paired: false)
        #expect(checks.isEmpty)
    }

    @Test("checks that ran become doctor checks; a failure fails the run and points to the cluster doctor")
    func ranChecksBecomeDoctorChecks() {
        let checks = clusterDoctorChecks([
            ("RDMA link", .passed, "rdma_en3 active on en3"),
            ("trust files", .failed, "the pairing's link key is missing"),
            ("live leader", .notObserved, "no leader observed"),
            ("recovery", .notRun, "read-only"),
        ])
        #expect(checks.map(\.name) == ["cluster RDMA link", "cluster trust files"])
        #expect(checks.map(\.status) == [.pass, .fail])
        #expect(checks[1].detail == "the pairing's link key is missing (details: `darkbloom cluster doctor`)")
        #expect(checks.contains { $0.status.isFailure(strict: false) })
    }

    @Test("a warning is a doctor WARN, not a failure: a pair set up before this Mac updated")
    func warningBecomesWarn() {
        let checks = clusterDoctorChecks([("localInstalledMetadata", .warning, "names the worker of Darkbloom 0.10.17")])
        #expect(checks.map(\.name) == ["cluster localInstalledMetadata"])
        #expect(checks.map(\.status) == [.warn])
        #expect(checks[0].detail == "names the worker of Darkbloom 0.10.17")
        #expect(!checks.contains { $0.status.isFailure(strict: false) })
    }
}
