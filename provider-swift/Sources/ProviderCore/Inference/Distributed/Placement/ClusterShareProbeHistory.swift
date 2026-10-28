import Foundation
import DarkbloomClusterPlacement
import DarkbloomClusterProtocol

/// Each member's recent tensor-parallel share probes (`ClusterShareProbeHistory`,
/// kept per model artifact and member in `~/.darkbloom/cluster/share-probes.json`)
/// as this provider keeps them: owner-only, replaced under the configuration
/// lock. The serving leader records both ranks' probes when the pair becomes
/// ready; every plan of that pair reads them for the model it plans, so a
/// re-plan balances the shares by each Mac's own measured steps, with no user
/// step.
extension ClusterShareProbeHistory {
    /// Nil when absent, unreadable, not owner-only or malformed.
    public static func read(_ file: URL) -> ClusterShareProbeHistory? {
        guard let data = try? ClusterConfigurationFiles.read(file, maximum: maximumBytes, privateMode: true) else { return nil }
        return decode(data)
    }

    /// Adds this load's probes as their members' newest points for the model
    /// (`recording`); other members and models stay. Never throws into
    /// serving: a pair whose probes cannot be kept plans as before.
    @discardableResult
    public static func record(_ probes: [Recorded], artifactSHA256: String, homeDirectory: URL,
                              now: Double = Date().timeIntervalSince1970) -> Bool {
        let usable = probes.filter(\.probe.valid)
        guard !usable.isEmpty, usable.count <= 2, Set(usable.map(\.member)).count == usable.count else { return false }
        let file = defaultFile(homeDirectory: homeDirectory)
        do {
            try ClusterConfigurationFiles.update(file, maximum: maximumBytes) { old in
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                // A file that is not a history (or another schema) is started again.
                let kept = old.flatMap(decode) ?? ClusterShareProbeHistory()
                let next = try encoder.encode(kept.recording(usable, artifactSHA256: artifactSHA256, now: now))
                // Within the bound by construction; should it ever not be, these probes alone are kept.
                if next.count <= maximumBytes { return next }
                return try encoder.encode(ClusterShareProbeHistory().recording(usable, artifactSHA256: artifactSHA256, now: now))
            }
            return true
        } catch { return false }
    }

    /// Each member's share rates for this model from its recent probes, by
    /// member ID; empty when none was measured (the plan is then as before).
    public static func shareRates(homeDirectory: URL, artifactSHA256: String, members: [String],
                                  now: Double = Date().timeIntervalSince1970) -> [String: [ClusterShareRate]] {
        read(defaultFile(homeDirectory: homeDirectory))?.shareRates(artifactSHA256: artifactSHA256, members: members, now: now) ?? [:]
    }
}
