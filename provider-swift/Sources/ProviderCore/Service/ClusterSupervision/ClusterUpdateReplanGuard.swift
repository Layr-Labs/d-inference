import Foundation

/// Declared only: nothing reads it yet.
public enum ClusterUpdateReplanGuard {
    public static let environmentKey = "DARKBLOOM_CLUSTER_UPDATE_REPLAN_GUARD"

    public static func isEnabled(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return true }
        return !["off", "false", "0", "none", "no", "disabled"].contains(value)
    }

    public static func enabled(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        isEnabled(environment[environmentKey])
    }

    public static func holdsReplan(_ progress: ClusterPairUpdateProgress?, running: String, now: Double) -> Bool { false }
}
