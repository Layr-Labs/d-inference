import Foundation
import ProviderCore

extension ClusterPairSummary {
    /// The rest of the pair's card under `clusterStatusLines` in `darkbloom status`: the cluster service's log, whether
    /// this Mac's service starts at login, and the commands that control the pair. `darkbloom cluster` ends on its ✓
    /// line alone and points here (owner, 2026-11-11: "Ending screen is too verbose"); the model, its split, the Macs,
    /// how it serves and its local API are in `clusterStatusLines` already. `afterRestart`: what happens after a restart
    /// of this Mac (`ClusterOnboardingRestart.thisMacLine`), said when its service starts at login.
    func statusCardLines(afterRestart: String? = nil) -> [String] {
        guard paired, !pairingUnreadable else { return [] }
        return ["Logs: " + ClusterUserPaths.serviceLogShown,
                startsAtLogin ? "Starts by itself at login on this Mac."
                    : "Doesn't start by itself at login on this Mac: `\(Self.cli) cluster` turns its cluster service on again."]
            + (startsAtLogin ? afterRestart.map { [$0] } ?? [] : [])
            + ["",
                "  \(Self.cli) stop     Stop both Macs",
                "  \(Self.cli) restart  Restart with the current model",
                "  \(Self.cli) cluster  Change the model"]
    }
}
