import DarkbloomClusterProtocol
import Foundation

/// The link as the pair's recent loads measured it (`ClusterWorkerLinkProbe`,
/// in each worker's ready record: every load over the cable, pipeline or
/// tensor parallel, measures it before it reads a weight), by pair of members,
/// in `~/.darkbloom/cluster/link-probes.json` (owner-only). The serving leader
/// adds each load's probe when the pair becomes ready (the provider keeps the
/// file); every plan of that pair reads them (`costs`), so a re-plan uses the
/// link as the pair's last loads measured it, with no user step, and the plan
/// tool reads the same file when it is given no link. Figures only: no name,
/// no address.
///
/// `pairs` names each pair's latest measurement, which carries the pair's
/// earlier ones, newest first, in `earlier`. A file an earlier build wrote
/// (the latest measurement only) reads as one measurement, and an earlier
/// build reads this one's latest and ignores the rest: one schema for both.
public struct ClusterLinkProbeHistory: Codable, Sendable, Equatable {
    public static let schemaName = "darkbloom_cluster_link_probes_v1"
    public static let maximumBytes = 65_536
    public static let maximumPairs = 16
    /// Measurements kept per pair, the latest included: enough that one odd
    /// load does not move the median (`ClusterLinkCosts(measurements:)`), few
    /// enough that a changed cable or Mac is the plan's basis within a few
    /// loads. Sixteen pairs of eight (at most about 360 bytes each, 47 KB in
    /// all) stay inside `maximumBytes`, which an earlier build also reads by.
    public static let maximumMeasurements = 8
    /// Older measurements are not used: a cable or a Mac may have changed.
    public static let maximumAgeSeconds = 30.0 * 86_400
    /// A measurement dated further ahead than this is not used (a clock set back since).
    public static let maximumFutureSeconds = 300.0

    public struct Measurement: Codable, Sendable, Equatable {
        public let measuredAt: Double
        public let probe: ClusterWorkerLinkProbe
        public init(measuredAt: Double, probe: ClusterWorkerLinkProbe) { self.measuredAt = measuredAt; self.probe = probe }
    }

    public struct Entry: Codable, Sendable, Equatable {
        /// The latest measurement, where an earlier build reads it.
        public let measuredAt: Double
        public let probe: ClusterWorkerLinkProbe
        /// The earlier measurements, newest first; nil when there are none
        /// (omitted then, as in a file an earlier build wrote).
        public let earlier: [Measurement]?

        /// Nil for no measurement.
        public init?(_ measurements: [Measurement]) {
            guard let latest = measurements.first else { return nil }
            measuredAt = latest.measuredAt; probe = latest.probe
            earlier = measurements.count > 1 ? Array(measurements.dropFirst()) : nil
        }

        /// Every measurement, newest first.
        public var measurements: [Measurement] { [.init(measuredAt: measuredAt, probe: probe)] + (earlier ?? []) }
    }

    public let schema: String
    public let pairs: [String: Entry]

    public init(pairs: [String: Entry] = [:]) { schema = Self.schemaName; self.pairs = pairs }

    public static func defaultFile(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(".darkbloom/cluster/link-probes.json")
    }

    /// The members in either order name one pair.
    public static func key(members: [String]) -> String { members.sorted().joined(separator: "|") }

    /// The file's bytes as a history; nil when malformed: another schema, more
    /// pairs or measurements than are kept, or any probe out of its bounds.
    public static func decode(_ data: Data) -> ClusterLinkProbeHistory? {
        guard data.count <= maximumBytes, let value = try? JSONDecoder().decode(ClusterLinkProbeHistory.self, from: data),
              value.schema == schemaName, value.pairs.count <= maximumPairs,
              value.pairs.values.allSatisfy({ entry in
                  entry.measurements.count <= maximumMeasurements
                      && entry.measurements.allSatisfy { $0.probe.valid && $0.measuredAt.isFinite }
              }) else { return nil }
        return value
    }

    /// This history with `probe` as the pair's latest measurement at `now`,
    /// ahead of the pair's earlier ones still in date, at most
    /// `maximumMeasurements` in all. Other pairs stay; past `maximumPairs`
    /// pairs only this one is kept.
    public func recording(_ probe: ClusterWorkerLinkProbe, members: [String], now: Double) -> ClusterLinkProbeHistory {
        let pair = Self.key(members: members)
        let earlier = (pairs[pair]?.measurements ?? []).filter { Self.inDate($0, now: now) }
        let entry = Entry([Measurement(measuredAt: now, probe: probe)] + earlier.prefix(Self.maximumMeasurements - 1))!
        var kept = pairs
        kept[pair] = entry
        return .init(pairs: kept.count > Self.maximumPairs ? [pair: entry] : kept)
    }

    /// The pair's measurements a plan at `now` may use, newest first: none
    /// older than `maximumAgeSeconds` or dated ahead.
    public func measurements(members: [String], now: Double) -> [Measurement] {
        (pairs[Self.key(members: members)]?.measurements ?? []).filter { Self.inDate($0, now: now) }
    }

    /// The planner's link costs for this pair (`ClusterLinkCosts(measurements:)`),
    /// or nil (unmeasured: no tensor-parallel mode is chosen then).
    public func costs(members: [String], now: Double) -> ClusterLinkCosts? {
        ClusterLinkCosts(measurements: measurements(members: members, now: now))
    }

    static func inDate(_ measurement: Measurement, now: Double) -> Bool {
        now - measurement.measuredAt <= maximumAgeSeconds && measurement.measuredAt <= now + maximumFutureSeconds
    }
}

extension ClusterLinkCosts {
    /// The link costs a pair's recent loads give together
    /// (`ClusterLinkProbeHistory`): each figure `init(probe:)` derives (the
    /// reduction's fixed part and per-byte slope, a pipeline decode step's
    /// records, a record's fixed part and per-byte slope, which price a prefill
    /// chunk's hop and a hand-off) is the median of what each load's probe
    /// gives, over the keyed probes when there are any (only those can choose
    /// tensor parallel), else over the plaintext ones. One probe gives exactly
    /// what `init(probe:)` gives.
    ///
    /// The median, not the latest: one pair's sealed all-sum cost 43 to 109 us
    /// per reduction from one load to the next (2026-10-23), around the 70 us
    /// at which its 9B's tensor parallel breaks even, so a plan on the latest
    /// probe alone changed the mode between loads. The median of the last
    /// loads moves at most one place with each new load, and one odd load (a
    /// busy Mac, a cold cache) does not move it. Not an upper quantile: that
    /// would hold every pair back from tensor parallel on top of the planner's
    /// own margin (`ClusterPlacementPolicy.tensorParallelMargin`), which
    /// already keeps a near tie on the mode that has run; the median is the
    /// cost the next load is as likely to beat as to miss. Nil when no probe
    /// is valid.
    public init?(measurements: [ClusterLinkProbeHistory.Measurement]) {
        let valid = measurements.filter { $0.probe.valid && $0.measuredAt.isFinite }
        let keyed = valid.filter(\.probe.keyed)
        let used = (keyed.isEmpty ? valid : keyed).sorted { $0.measuredAt > $1.measuredAt }
        let formatter = ISO8601DateFormatter()
        func utc(_ m: ClusterLinkProbeHistory.Measurement) -> String { formatter.string(from: Date(timeIntervalSince1970: m.measuredAt)) }
        let each = used.compactMap { ClusterLinkCosts(probe: $0.probe, measuredUTC: utc($0)) }
        guard let latest = used.first, let oldest = used.last, each.count == used.count else { return nil }
        if each.count == 1 { self = each[0]; return }
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted(), middle = sorted.count / 2
            return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
        }
        let fixedEach = each.map { $0.reduction?.fixedSeconds ?? 0 }
        let fixed = median(fixedEach), slope = median(each.map { $0.reduction?.secondsPerByte ?? 0 })
        let step = median(each.map { $0.perDecodeStepSeconds[ClusterGenerationMode.pipeline.rawValue] ?? 0 })
        let chunk = median(each.map(\.perChunkSeconds)), handoff = median(each.map(\.handoffSecondsPerByte))
        let record = median(each.map { $0.recordFixedSeconds ?? 0 })
        let provenance = "the median of \(used.count) loads' probes over \(latest.probe.transport) "
            + "(\(keyed.isEmpty ? "plaintext" : "keyed, sealed all-sums")), measured \(utc(oldest)) to \(utc(latest)): "
            + String(format: "a reduction %.0f us fixed (%.0f to %.0f us across the loads) + %.3f ns a byte; "
                + "a pipeline decode step's records %.0f us; a record (a prefill chunk's hop) %.0f us + %.3f ns a byte",
                fixed * 1e6, (fixedEach.min() ?? 0) * 1e6, (fixedEach.max() ?? 0) * 1e6, slope * 1e9, step * 1e6,
                record * 1e6, handoff * 1e9)
        self = ClusterLinkCosts(measured: true, perChunkSeconds: chunk,
            perDecodeStepSeconds: Dictionary(uniqueKeysWithValues: ClusterGenerationMode.allCases
                .filter { !$0.usesTensorParallelPrefill }.map { ($0.rawValue, step) }),
            handoffSecondsPerByte: handoff, provenance: String(provenance.prefix(1024)),
            reduction: .init(fixedSeconds: fixed, secondsPerByte: slope, keyed: !keyed.isEmpty,
                provenance: String(provenance.prefix(1024))),
            recordFixedSeconds: record)
    }
}
