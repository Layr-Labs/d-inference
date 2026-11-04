import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// `darkbloom doctor` on a Mac set up for a two-Mac cluster: the pair holds
/// this Mac's share of its model, so the single-Mac cold-load verdict gives way
/// to one informational row (the 2026-11-03 two-Mac test: a healthy serving
/// pair failed "model fits in RAM" for its own model and doctor exited 1).
@Suite("Doctor model fit on a cluster Mac")
struct DoctorClusterModelFitTests {
    @Test("only a Mac with a saved cluster setup and a pairing is a cluster member; the pairing is read only then")
    func clusterMemberNeedsSetupAndPairing() throws {
        let plain = ProviderConfig.defaultForHardware(CLICommandSandbox.hardware)
        var set = plain
        set.cluster = try ClusterConfigurationReference(
            configuration: "/tmp/darkbloom-cluster-configuration.json", sha256: String(repeating: "a", count: 64))
        // Outside `#expect`, which evaluates a call's arguments itself to show them.
        var asked = false
        let plainServes = DoctorRunner.servesCluster(plain, paired: { asked = true; return true }())
        #expect(!plainServes)
        #expect(!asked)
        #expect(DoctorRunner.servesCluster(set, paired: true))
        #expect(!DoctorRunner.servesCluster(set, paired: false))
    }

    @Test("the cluster member's row is informational, not a failure, and points to the cluster doctor")
    func clusterMemberRow() {
        let row = ModelFitDiagnostic.clusterMember()
        #expect(row.name == "model fits in RAM")
        #expect(row.section == .traffic)
        #expect(row.level == .info)
        #expect(row.message.contains("cluster doctor"))
    }
}
