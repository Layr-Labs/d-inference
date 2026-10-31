import DarkbloomClusterProtocol
import Foundation

/// Each Mac's own tensor-parallel share steps as its loads measured them
/// (`ClusterWorkerShareProbe`, in each worker's ready record: a dense Qwen
/// tensor-parallel load times its own share alone before it serves), by model
/// artifact and member, in `~/.darkbloom/cluster/share-probes.json`
/// (owner-only). The serving leader adds both ranks' probes when the pair
/// becomes ready (the provider keeps the file); every plan of the pair reads
/// each member's points for the model it plans (`shareRates`) as that Mac's
/// share steps, so the next plan balances the shares by what the Macs
/// measured, with no user step. Figures only: no name, no address.
///
/// A member keeps its newest point per share, at most `maximumShares`, all
/// from one worker build: a probe from another build starts the member's
/// points again (a build changes the kernels a share runs). Points older than
/// `maximumAgeSeconds` or dated ahead are not used.
public struct ClusterShareProbeHistory: Codable, Sendable, Equatable {
    public static let schemaName = "darkbloom_cluster_share_probes_v1"
    public static let maximumBytes = 65_536
    /// Models kept, the ones measured last; members kept per model; shares
    /// kept per member (the planner offers seven two-rank splits). Eight
    /// models of four members of eight points (about 180 bytes each, 48 KB in
    /// all) stay inside `maximumBytes`.
    public static let maximumArtifacts = 8
    public static let maximumMembers = 4
    public static let maximumShares = 8
    /// Older points are not used: the Mac, its build or its macOS may have changed.
    public static let maximumAgeSeconds = 30.0 * 86_400
    /// A point dated further ahead than this is not used (a clock set back since).
    public static let maximumFutureSeconds = 300.0

    public struct Point: Codable, Sendable, Equatable {
        public let measuredAt: Double
        public let probe: ClusterWorkerShareProbe
        public init(measuredAt: Double, probe: ClusterWorkerShareProbe) { self.measuredAt = measuredAt; self.probe = probe }
    }

    public struct Member: Codable, Sendable, Equatable {
        /// The worker build every point was measured by.
        public let buildSHA256: String
        /// Newest first, one per share.
        public let points: [Point]
        public init(buildSHA256: String, points: [Point]) { self.buildSHA256 = buildSHA256; self.points = points }
    }

    /// One rank's probe as the pair's owner records it.
    public struct Recorded: Sendable, Equatable {
        public let member: String
        public let buildSHA256: String
        public let probe: ClusterWorkerShareProbe
        public init(member: String, buildSHA256: String, probe: ClusterWorkerShareProbe) {
            self.member = member; self.buildSHA256 = buildSHA256; self.probe = probe
        }
    }

    public let schema: String
    /// Model artifact SHA-256, then member ID.
    public let artifacts: [String: [String: Member]]

    public init(artifacts: [String: [String: Member]] = [:]) { schema = Self.schemaName; self.artifacts = artifacts }

    public static func defaultFile(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(".darkbloom/cluster/share-probes.json")
    }

    static func hash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func label(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value < 127 }
    }

    /// The file's bytes as a history; nil when malformed: another schema, more
    /// models, members or shares than are kept, a share twice, or any probe
    /// out of its bounds.
    public static func decode(_ data: Data) -> ClusterShareProbeHistory? {
        guard data.count <= maximumBytes, let value = try? JSONDecoder().decode(ClusterShareProbeHistory.self, from: data),
              value.schema == schemaName, value.artifacts.count <= maximumArtifacts,
              value.artifacts.allSatisfy({ artifact, members in
                  hash(artifact) && members.count <= maximumMembers && members.allSatisfy { id, member in
                      label(id) && hash(member.buildSHA256) && member.points.count <= maximumShares
                          && Set(member.points.map(\.probe.sharePerMille)).count == member.points.count
                          && member.points.allSatisfy { $0.probe.valid && $0.measuredAt.isFinite }
                  }
              }) else { return nil }
        return value
    }

    /// This history with `probes` as their members' newest points for
    /// `artifactSHA256` at `now`: each replaces that member's point at the
    /// same share and goes ahead of its other points still in date, or starts
    /// them again when its build differs. Other members and models stay,
    /// within the bounds: past them the ones measured longest ago go.
    public func recording(_ probes: [Recorded], artifactSHA256: String, now: Double) -> ClusterShareProbeHistory {
        let usable = probes.filter { $0.probe.valid && Self.label($0.member) && Self.hash($0.buildSHA256) }
        guard Self.hash(artifactSHA256), now.isFinite, !usable.isEmpty else { return self }
        var members = artifacts[artifactSHA256] ?? [:]
        for value in usable {
            let earlier = members[value.member].flatMap { $0.buildSHA256 == value.buildSHA256 ? $0.points : nil } ?? []
            let kept = earlier.filter { Self.inDate($0, now: now) && $0.probe.sharePerMille != value.probe.sharePerMille }
            members[value.member] = .init(buildSHA256: value.buildSHA256,
                points: [Point(measuredAt: now, probe: value.probe)] + kept.prefix(Self.maximumShares - 1))
        }
        // Measured last first; equal dates by name, so every Mac keeps the same ones.
        func newest(_ member: Member) -> Double { member.points.map(\.measuredAt).max() ?? -.infinity }
        func newestOf(_ members: [String: Member]) -> Double { members.values.map(newest).max() ?? -.infinity }
        let recorded = Set(usable.map(\.member))
        if members.count > Self.maximumMembers {
            let others = members.filter { !recorded.contains($0.key) }
                .sorted { newest($0.value) != newest($1.value) ? newest($0.value) > newest($1.value) : $0.key < $1.key }
            members = members.filter { recorded.contains($0.key) }
            for (id, member) in others.prefix(max(0, Self.maximumMembers - members.count)) { members[id] = member }
        }
        var kept = artifacts
        kept[artifactSHA256] = members
        if kept.count > Self.maximumArtifacts {
            let others = kept.filter { $0.key != artifactSHA256 }
                .sorted { newestOf($0.value) != newestOf($1.value) ? newestOf($0.value) > newestOf($1.value) : $0.key < $1.key }
            kept = [artifactSHA256: members]
            for (artifact, value) in others.prefix(Self.maximumArtifacts - 1) { kept[artifact] = value }
        }
        return .init(artifacts: kept)
    }

    /// One member's points for this model a plan at `now` may use, as share
    /// rates (the probe measures no prefill): none older than
    /// `maximumAgeSeconds` or dated ahead. A load that serves the speculative
    /// head decodes in verify windows, so its rate is the window's: the
    /// window's target positions over its step (`decodeRate`). The shares then
    /// balance the step the rounds actually run: a Mac that is faster per
    /// token but slower per window (the M3 Ultra against the M5 Max for the
    /// 27B, c40) no longer takes the larger share. A load without the head
    /// keeps one over its plain step.
    public func shareRates(artifactSHA256: String, member: String, now: Double) -> [ClusterShareRate] {
        (artifacts[artifactSHA256]?[member]?.points ?? []).filter { Self.inDate($0, now: now) && $0.probe.valid }.map {
            ClusterShareRate(sharePerMille: $0.probe.sharePerMille, decodeTokensPerSecond: Self.decodeRate($0.probe))
        }
    }

    /// Target positions a second in the step a load's rounds run: the verify
    /// window when the probe measured one, else the plain step.
    static func decodeRate(_ probe: ClusterWorkerShareProbe) -> Double {
        if let columns = probe.windowColumns, let window = probe.windowStepMicroseconds, columns > 0, window > 0 {
            return Double(columns) * 1e6 / Double(window)
        }
        return 1e6 / Double(probe.plainStepMicroseconds)
    }

    /// `shareRates` for each of `members` that has any, by member ID.
    public func shareRates(artifactSHA256: String, members: [String], now: Double) -> [String: [ClusterShareRate]] {
        var result: [String: [ClusterShareRate]] = [:]
        for member in members {
            let rates = shareRates(artifactSHA256: artifactSHA256, member: member, now: now)
            if !rates.isEmpty { result[member] = rates }
        }
        return result
    }

    static func inDate(_ point: Point, now: Double) -> Bool {
        now - point.measuredAt <= maximumAgeSeconds && point.measuredAt <= now + maximumFutureSeconds
    }
}

extension ClusterPlacementDevice {
    /// This device with its own share probes from `rates` (by device label,
    /// which is the member ID in a setup's plan) added to its speed
    /// (`ClusterDeviceSpeed.addingShareRates`); unchanged without any.
    public func addingShareRates(_ rates: [String: [ClusterShareRate]]) -> ClusterPlacementDevice {
        guard let points = rates[label], !points.isEmpty else { return self }
        return .init(label: label, profile: profile, speed: speed.addingShareRates(points))
    }
}
