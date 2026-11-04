import Foundation
import ProviderCore

/// `darkbloom doctor`'s cluster checks: on a Mac paired for a cluster, the checks `darkbloom cluster doctor` runs
/// (installed metadata, trust files, the Thunderbolt RDMA link, the saved setup), each as one doctor check, so one
/// command answers for the whole Mac (2026-11-02 onboarding review: "darkbloom doctor > integrate clustering"). A Mac
/// that is not paired gets none: a single-Mac provider's report is unchanged, and its link is never inspected.
func buildClusterDoctorChecks(configPath: String?,
                              paired: Bool = ClusterPairSummary.readsThisMacsCluster && !ClusterService.holdsNoPairing()) async -> [DoctorCheck] {
    guard paired, let path = configPath ?? (try? ConfigManager.defaultConfigPath().path), path.hasPrefix("/") else { return [] }
    let report = await ClusterDiagnostics.doctor(providerConfiguration: URL(fileURLWithPath: path))
    return clusterDoctorChecks(report.checks.map { ($0.name, $0.outcome, $0.detail) })
}

extension Doctor {
    /// The header's daemon line: on a Mac in a cluster no single-Mac provider is expected, so nothing points at
    /// `darkbloom start` (which would start one beside the cluster). `unsure`: its pairing record couldn't be read.
    static func daemonLine(running: Bool, paired: Bool, unsure: Bool = false) -> String {
        if running { return "Daemon: running" }
        guard paired else { return "Daemon: NOT running — run `\(BuildEnvironment.current.cliName) start`" }
        return unsure ? "Daemon: single-Mac serving off (this Mac may be in a two-Mac cluster)"
            : "Daemon: single-Mac serving off (this Mac serves in its two-Mac cluster)"
    }
}

/// The cluster checks that ran, named as cluster checks; one that could not run or observe anything is left out
/// (`darkbloom cluster doctor` lists those).
func clusterDoctorChecks(_ checks: [(name: String, outcome: ClusterDiagnosticsReport.Outcome, detail: String)]) -> [DoctorCheck] {
    checks.compactMap { check in
        switch check.outcome {
        case .passed: return DoctorCheck(name: "cluster \(check.name)", status: .pass, detail: check.detail)
        case .failed: return DoctorCheck(name: "cluster \(check.name)", status: .fail,
                                         detail: check.detail + " (details: `\(ClusterPairSummary.cli) cluster doctor`)")
        case .notRun, .notObserved: return nil
        }
    }
}
