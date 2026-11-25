import Foundation

/// A pair whose split one Mac's load gate refuses (`memory_gate_refused`). The planner priced that Mac's share on its
/// free pages plus its file cache, as the gate counts them on one sample at normal pressure, but the gate withdraws the
/// cache mid-load once the load has compressed or swapped out past its limits, as on a Mac short of free pages beside
/// other programs' memory. The re-plan after two refusals (`ClusterService.replanForMemory`) priced it the same way and
/// chose the same split, and the part started again every 30 s, reading its share each time (a DevNet pair,
/// 2026-11-15: Gemma 4 26B's 29 layers on the MacBook, refused on 3.09 GiB free "plus no file cache"). Now that re-plan
/// puts the splits each Mac's free pages hold first (`ClusterPlacementPolicy.freePagesFirst`), and the leading Mac's
/// part refused for memory waits twice as long after each such end, up to five minutes
/// (`ClusterControlPartChoice.restartBackoff`).
///
/// The switch is read by the cluster service, from the environment its login agent carries
/// (`LaunchAgent.passthroughEnvKeys`: export it before `darkbloom start` or `darkbloom cluster`). An off word (`off`,
/// `false`, `0`, `none`, `no` or `disabled`, in any case, surrounding space ignored) restores 0.10.14's behaviour.
public enum ClusterMemoryRefusalReplan {
    public static let environmentKey = "DARKBLOOM_CLUSTER_MEMORY_REFUSAL_REPLAN"

    public static func isEnabled(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return true }
        return !["off", "false", "0", "none", "no", "disabled"].contains(value)
    }

    public static func enabled(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        isEnabled(environment[environmentKey])
    }
}
