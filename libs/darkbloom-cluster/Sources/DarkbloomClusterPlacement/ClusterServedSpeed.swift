import DarkbloomClusterProtocol
import Foundation

/// How fast one request a setup served actually ran, as the leader observed
/// it: the raw material of speed records written from serving. Values only:
/// no prompt, no token, no client identity, no machine name (`member` is the
/// setup's member label).
public struct ClusterServedSample: Codable, Equatable, Sendable {
    public enum Route: String, Codable, Sendable {
        /// Both members, as the setup places the model.
        case pair
        /// One member, holding the whole model, alone (`member`).
        case alone
    }

    public let route: Route
    /// The member that served an `alone` request; nil for the pair.
    public let member: String?
    public let promptTokens: Int
    public let outputTokens: Int
    /// From admission to the first committed token.
    public let firstTokenSeconds: Double
    /// Tokens after the first per second; nil for a one-token answer.
    public let decodeTokensPerSecond: Double?
    /// Seconds since 1970 (UTC).
    public let finishedAt: Double

    public init(route: Route, member: String?, promptTokens: Int, outputTokens: Int, firstTokenSeconds: Double,
                decodeTokensPerSecond: Double?, finishedAt: Double) {
        self.route = route; self.member = member; self.promptTokens = promptTokens; self.outputTokens = outputTokens
        self.firstTokenSeconds = firstTokenSeconds; self.decodeTokensPerSecond = decodeTokensPerSecond
        self.finishedAt = finishedAt
    }

    /// A sample is evidence only when it is finite, positive and names a member exactly when it ran alone.
    public var valid: Bool {
        promptTokens > 0 && outputTokens > 0 && firstTokenSeconds.isFinite && firstTokenSeconds > 0
            && (decodeTokensPerSecond.map { $0.isFinite && $0 > 0 } ?? true) && finishedAt.isFinite
            && (route == .alone) == (member != nil) && (member.map { !$0.isEmpty && $0.utf8.count <= 64 } ?? true)
    }
}

/// Speed records written from served requests, per setup: the model, the
/// generation mode and the layers each rank holds (`0-4|4-32`, rank 0 first),
/// which is what the leader's pair telemetry names a request's setup by.
/// Kept across serving sessions (the telemetry log keeps one session), newest
/// last, bounded per setup and route so that old hardware states age out.
public struct ClusterServedSpeedRecords: Codable, Equatable, Sendable {
    public static let schemaName = "darkbloom_cluster_served_speed_v1"
    public static let maximumEncodedBytes = 1 << 20
    /// Samples kept per setup and route (member, for `alone`).
    public static let keptPerRoute = 32

    public struct Setup: Codable, Hashable, Sendable {
        public let modelID: String
        public let mode: String
        public let cut: String
        /// The members' labels in rank order, when the writer knew them: the
        /// calibration needs to know which Mac held which range.
        public let ranks: [String]?
        public init(modelID: String, mode: String, cut: String, ranks: [String]? = nil) {
            self.modelID = modelID; self.mode = mode; self.cut = cut; self.ranks = ranks
        }

        /// The cuts of a `0-4|4-32` cut string over `layerCount` layers; nil when it is not one.
        public static func cuts(_ cut: String, layerCount: Int) -> [Int]? {
            let ranges = cut.split(separator: "|").map { $0.split(separator: "-").compactMap { Int($0) } }
            guard ranges.count >= 2, ranges.allSatisfy({ $0.count == 2 && $0[0] < $0[1] }), ranges.first?[0] == 0,
                  ranges.last?[1] == layerCount, zip(ranges, ranges.dropFirst()).allSatisfy({ $0.0[1] == $0.1[0] }) else { return nil }
            return ranges.dropLast().map { $0[1] }
        }

        /// `0-4|4-32` for a placement's cuts over `layerCount` layers, rank 0 first.
        public static func cut(_ cuts: [Int], layerCount: Int) -> String {
            let bounds = [0] + cuts + [layerCount]
            return (0..<(bounds.count - 1)).map { "\(bounds[$0])-\(bounds[$0 + 1])" }.joined(separator: "|")
        }
    }

    public struct Entry: Codable, Equatable, Sendable {
        public let setup: Setup
        public let sample: ClusterServedSample
        public init(setup: Setup, sample: ClusterServedSample) { self.setup = setup; self.sample = sample }
    }

    public let schema: String
    public private(set) var entries: [Entry]

    public init(entries: [Entry] = []) {
        schema = Self.schemaName; self.entries = []
        for entry in entries { add(entry.sample, setup: entry.setup) }
    }

    public static func decode(_ data: Data) throws -> ClusterServedSpeedRecords {
        guard data.count <= maximumEncodedBytes else { throw ClusterPlacementError("Served speed records are too large") }
        let value = try JSONDecoder().decode(ClusterServedSpeedRecords.self, from: data)
        try value.validate()
        return value
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Adds one served request; an invalid sample is dropped. The oldest
    /// sample of the same setup and route goes once that route keeps
    /// `keptPerRoute`.
    public mutating func add(_ sample: ClusterServedSample, setup: Setup) {
        guard sample.valid, !setup.modelID.isEmpty, setup.modelID.utf8.count <= 256, setup.mode.utf8.count <= 64,
              setup.cut.utf8.count <= 256, (setup.ranks ?? []).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 }) else { return }
        entries.append(.init(setup: setup, sample: sample))
        let same = entries.indices.filter {
            entries[$0].setup == setup && entries[$0].sample.route == sample.route && entries[$0].sample.member == sample.member
        }
        if same.count > Self.keptPerRoute {
            let drop = Set(same.prefix(same.count - Self.keptPerRoute))
            entries = entries.indices.filter { !drop.contains($0) }.map { entries[$0] }
        }
    }

    /// This setup's samples, oldest first.
    public func samples(for setup: Setup) -> [ClusterServedSample] {
        entries.filter { $0.setup == setup }.map(\.sample)
    }

    public func validate() throws {
        guard schema == Self.schemaName, entries.allSatisfy({ $0.sample.valid }) else {
            throw ClusterPlacementError("Served speed records are malformed")
        }
    }
}

/// Turns what a setup served into speed measurements the planner uses on its
/// next plan, for any devices and any model: no table, no chip name.
///
/// - A request served by one member alone measured that member's whole-model
///   prefill (prompt / first token) and decode directly.
/// - A request served by the pair measured the placement as a whole. The
///   devices' current estimates (often only the model-free index's ratios)
///   fix how its prefill divides between them; the observed first token then
///   fixes the absolute scale. Under a phase split the decode after the
///   first token is the decoding member's whole-model rate (with the head
///   when the mode runs it); under a pipeline the observed step fixes the
///   decode scale the same way.
public enum ClusterServedCalibration {
    /// The placement the samples were served on, devices in rank order with
    /// the estimates they had before any served sample.
    public struct Placement: Sendable {
        public let devices: [ClusterPlacementDevice]
        public let cuts: [Int]
        public let mode: ClusterGenerationMode
        public let schedule: ClusterPrefillSchedule
        public let layout: ClusterModelLayout
        public let link: ClusterLinkCosts
        public init(devices: [ClusterPlacementDevice], cuts: [Int], mode: ClusterGenerationMode,
                    schedule: ClusterPrefillSchedule, layout: ClusterModelLayout, link: ClusterLinkCosts = .unmeasured) {
            self.devices = devices; self.cuts = cuts; self.mode = mode; self.schedule = schedule
            self.layout = layout; self.link = link
        }
    }

    static func median(_ values: [Double]) -> Double? {
        let sorted = values.filter { $0.isFinite && $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// One measurement per device the samples say something about, keyed to
    /// `artifactSHA256` and each device's chip and OS build, labelled as
    /// derived from served requests. Empty when no sample is usable.
    public static func measurements(_ samples: [ClusterServedSample], placement: Placement,
                                    runtimeBinarySHA256: String, measuredUTC: String) throws -> [ClusterSpeedMeasurement] {
        let layout = placement.layout, devices = placement.devices
        let usable = samples.filter(\.valid)
        guard !usable.isEmpty, devices.count == placement.cuts.count + 1 else { return [] }
        var policy = ClusterPlacementPolicy()
        func pairPrediction(_ s: ClusterServedSample) throws -> ClusterPlacementPrediction {
            policy.promptTokens = s.promptTokens; policy.outputTokens = max(1, s.outputTokens)
            return try ClusterPlacementPlanner.evaluate(devices: devices, cuts: placement.cuts, mode: placement.mode,
                prefillSchedule: placement.schedule, layout: layout, policy: policy, link: placement.link).rested
        }
        let pair = usable.filter { $0.route == .pair }
        // Absolute scale of the current prefill estimates: predicted over observed first token.
        let prefillScale = median(try pair.map { try pairPrediction($0).firstTokenSeconds / $0.firstTokenSeconds })
        // Pipeline decode passes every range each step: its observed rate scales every device.
        var decodeScales: [Double] = []
        if !placement.mode.isPhaseSplit {
            for s in pair { if let observed = s.decodeTokensPerSecond { decodeScales.append(observed / (try pairPrediction(s).decodeTokensPerSecond)) } }
        }
        let decodeScale = median(decodeScales)
        let decoder = devices.last?.label
        let phaseDecode = placement.mode.isPhaseSplit ? median(pair.compactMap(\.decodeTokensPerSecond)) : nil
        var result: [ClusterSpeedMeasurement] = []
        for device in devices {
            let base = device.speed.rested
            let alone = usable.filter { $0.route == .alone && $0.member == device.label }
            var prefill = median(alone.map { Double($0.promptTokens) / $0.firstTokenSeconds })
                ?? prefillScale.map { base.prefillTokensPerSecond * $0 }
            // Decode measured by this device alone, or as the phase split's decoding rank.
            let own = median(alone.compactMap(\.decodeTokensPerSecond)) ?? (device.label == decoder ? phaseDecode : nil)
            let head = placement.mode.usesSpeculativeHead
                && ClusterSpeculativeCredit.prefersHead(base, device: device, layout: layout)
            var decode: Double?, speculative: Double?
            if let own {
                if head {
                    // The observed rate is with the head; the plain rate is the
                    // row's factor below it, or as fast when the row has none.
                    speculative = own; decode = own / max(1, layout.speculativeDecodeFactor ?? 1)
                } else { decode = own }
            } else if let decodeScale {
                decode = base.decodeTokensPerSecond * decodeScale
            } else if let decoder, let observed = phaseDecode,
                      let reference = devices.first(where: { $0.label == decoder }), reference.label != device.label {
                // Scaled by the ratio the estimates give against the decoding rank.
                let referenceHead = placement.mode.usesSpeculativeHead
                    && ClusterSpeculativeCredit.prefersHead(reference.speed.rested, device: reference, layout: layout)
                let plain = referenceHead ? observed / max(1, layout.speculativeDecodeFactor ?? 1) : observed
                decode = base.decodeTokensPerSecond * plain / reference.speed.rested.decodeTokensPerSecond
            }
            // A device the samples say nothing absolute about keeps its estimate.
            if prefill == nil && decode == nil { continue }
            if prefill == nil, device.speed.absolute { prefill = base.prefillTokensPerSecond }
            if decode == nil, device.speed.absolute { decode = base.decodeTokensPerSecond }
            guard let prefill, let decode, prefill.isFinite, decode.isFinite, prefill > 0, decode > 0 else { continue }
            let used = alone.isEmpty ? pair : alone
            let prompt = Int(median(used.map { Double($0.promptTokens) }) ?? Double(layout.maximumChunkTokens))
            let how = alone.isEmpty
                ? "derived from \(pair.count) request(s) the pair served (\(placement.mode.rawValue), cut \(ClusterServedSpeedRecords.Setup.cut(placement.cuts, layerCount: layout.layerCount)))"
                : "derived from \(alone.count) request(s) this Mac served alone"
            result.append(try .init(key: .init(artifactSHA256: layout.artifactSHA256, chip: device.profile.chip,
                    osBuild: device.profile.osBuild, runtimeBinarySHA256: runtimeBinarySHA256,
                    probe: "served_\(placement.mode.rawValue)_v1"),
                promptTokens: max(1, prompt), chunkTokens: layout.maximumChunkTokens, probedLayers: layout.layerCount,
                layerCount: layout.layerCount,
                rested: .init(prefillTokensPerSecond: prefill, decodeTokensPerSecond: decode,
                    speculativeDecodeTokensPerSecond: speculative),
                sustained: nil, measuredUTC: measuredUTC, provenance: how))
        }
        return result
    }
}
