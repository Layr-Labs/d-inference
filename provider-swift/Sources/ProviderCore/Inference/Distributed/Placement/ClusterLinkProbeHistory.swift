import Foundation
import DarkbloomClusterPlacement
import DarkbloomClusterProtocol

/// The pair's recent link probes (`ClusterLinkProbeHistory`, kept per pair of
/// members in `~/.darkbloom/cluster/link-probes.json`) as this provider keeps
/// them: owner-only, replaced under the configuration lock. The serving
/// leader records each load's probe when the pair becomes ready; every plan of
/// that pair reads them, so a re-plan uses the link as the pair's last loads
/// measured it (their median, `ClusterLinkCosts(measurements:)`), with no user
/// step.
extension ClusterLinkProbeHistory {
    /// Nil when absent, unreadable, not owner-only or malformed.
    public static func read(_ file: URL) -> ClusterLinkProbeHistory? {
        guard let data = try? ClusterConfigurationFiles.read(file, maximum: maximumBytes, privateMode: true) else { return nil }
        return decode(data)
    }

    /// Adds this load's measurement to the pair's (`recording`); other pairs
    /// stay. Never throws into serving: a pair whose probe cannot be kept
    /// plans as before.
    @discardableResult
    public static func record(_ probe: ClusterWorkerLinkProbe, members: [String], homeDirectory: URL,
                              now: Double = Date().timeIntervalSince1970) -> Bool {
        guard probe.valid, members.count == 2, Set(members).count == 2 else { return false }
        let file = defaultFile(homeDirectory: homeDirectory)
        do {
            try ClusterConfigurationFiles.update(file, maximum: maximumBytes) { old in
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                // A file that is not a history (or another schema) is started again.
                let kept = old.flatMap(decode) ?? ClusterLinkProbeHistory()
                let next = try encoder.encode(kept.recording(probe, members: members, now: now))
                // Within the bound by construction; should it ever not be, this measurement alone is kept.
                if next.count <= maximumBytes { return next }
                return try encoder.encode(ClusterLinkProbeHistory().recording(probe, members: members, now: now))
            }
            return true
        } catch { return false }
    }

    /// The planner's link costs for this pair from its recent measurements
    /// (their median), or nil (unmeasured: no tensor-parallel mode is chosen then).
    public static func costs(homeDirectory: URL, members: [String],
                             now: Double = Date().timeIntervalSince1970) -> ClusterLinkCosts? {
        read(defaultFile(homeDirectory: homeDirectory))?.costs(members: members, now: now)
    }
}
