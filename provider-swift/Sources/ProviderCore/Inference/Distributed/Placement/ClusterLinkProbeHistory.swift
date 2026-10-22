import Foundation
import DarkbloomClusterPlacement
import DarkbloomClusterProtocol

/// The link as the pair's last load measured it (`ClusterWorkerLinkProbe`, in
/// each worker's ready record: every load over the cable, pipeline or tensor
/// parallel, measures it before it reads a weight), by pair of members, in
/// `~/.darkbloom/cluster/link-probes.json` (owner-only). The serving leader
/// writes it when the pair becomes ready; every plan of that pair reads it
/// (`ClusterLinkCosts(probe:)`), so a re-plan always uses the link as it was
/// last measured, with no user step. Figures only: no name, no address.
public struct ClusterLinkProbeHistory: Codable, Sendable, Equatable {
    public static let schemaName = "darkbloom_cluster_link_probes_v1"
    public static let maximumBytes = 65_536
    public static let maximumPairs = 16
    /// Older measurements are not used: a cable or a Mac may have changed.
    public static let maximumAgeSeconds = 30.0 * 86_400

    public struct Entry: Codable, Sendable, Equatable {
        public let measuredAt: Double
        public let probe: ClusterWorkerLinkProbe
    }
    public let schema: String
    public let pairs: [String: Entry]

    public static func defaultFile(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(".darkbloom/cluster/link-probes.json")
    }

    /// The members in either order name one pair.
    public static func key(members: [String]) -> String { members.sorted().joined(separator: "|") }

    /// Nil when absent, unreadable, not owner-only or malformed.
    public static func read(_ file: URL) -> ClusterLinkProbeHistory? {
        guard let data = try? ClusterConfigurationFiles.read(file, maximum: maximumBytes, privateMode: true),
              let value = try? JSONDecoder().decode(ClusterLinkProbeHistory.self, from: data),
              value.schema == schemaName, value.pairs.count <= maximumPairs,
              value.pairs.values.allSatisfy({ $0.probe.valid }) else { return nil }
        return value
    }

    /// Replaces this pair's measurement; other pairs stay. Never throws into
    /// serving: a pair whose probe cannot be kept plans as before.
    @discardableResult
    public static func record(_ probe: ClusterWorkerLinkProbe, members: [String], homeDirectory: URL,
                              now: Double = Date().timeIntervalSince1970) -> Bool {
        guard probe.valid, members.count == 2, Set(members).count == 2 else { return false }
        let file = defaultFile(homeDirectory: homeDirectory)
        do {
            try ClusterConfigurationFiles.update(file, maximum: maximumBytes) { old in
                var kept = old.flatMap { try? JSONDecoder().decode(ClusterLinkProbeHistory.self, from: $0) }?.pairs ?? [:]
                kept[key(members: members)] = .init(measuredAt: now, probe: probe)
                if kept.count > maximumPairs { kept = [key(members: members): .init(measuredAt: now, probe: probe)] }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                return try encoder.encode(ClusterLinkProbeHistory(schema: schemaName, pairs: kept))
            }
            return true
        } catch { return false }
    }

    /// The planner's link costs for this pair from its latest measurement, or
    /// nil (unmeasured: no tensor-parallel mode is chosen then).
    public static func costs(homeDirectory: URL, members: [String],
                             now: Double = Date().timeIntervalSince1970) -> ClusterLinkCosts? {
        guard let entry = read(defaultFile(homeDirectory: homeDirectory))?.pairs[key(members: members)],
              now - entry.measuredAt <= maximumAgeSeconds, entry.measuredAt <= now + 300 else { return nil }
        return ClusterLinkCosts(probe: entry.probe,
            measuredUTC: ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: entry.measuredAt)))
    }
}
