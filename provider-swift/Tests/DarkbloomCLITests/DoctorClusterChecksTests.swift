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
}
