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
/// which is what the leader's pair telemetry names a request's setup by, and
/// the worker build each rank served with. Kept across serving sessions (the
/// telemetry log keeps one session), newest last, bounded per setup and route
/// so that old hardware states age out.
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
        /// The worker build each rank served with, rank order: the SHA-256 of
        /// that rank's worker binary as the pair's admission identity names it
        /// (`ClusterWorkerIdentity.peers[].buildSHA256`, the value share probes
        /// and the prefix SSD scope use). A served speed is evidence only for
        /// the build that served it, so a plan or a route uses only the setups
        /// its own builds served (`servedBy`). Nil in a record written before
        /// builds were recorded, which counts as another build's.
        public let rankBuildSHA256: [String]?
        public init(modelID: String, mode: String, cut: String, ranks: [String]? = nil, rankBuildSHA256: [String]? = nil) {
            self.modelID = modelID; self.mode = mode; self.cut = cut; self.ranks = ranks; self.rankBuildSHA256 = rankBuildSHA256
        }

        /// Whether every rank of this setup ran the worker build `builds` names
        /// for its member (member ID: SHA-256 of that member's worker binary).
        /// A setup that names no ranks or no builds, or other builds, was not
        /// served by these builds.
        public func servedBy(_ builds: [String: String]) -> Bool {
            guard let ranks, let served = rankBuildSHA256, !ranks.isEmpty, ranks.count == served.count else { return false }
            return zip(ranks, served).allSatisfy { builds[$0.0] == $0.1 }
        }

        /// A worker build's SHA-256: 64 lowercase hexadecimal digits.
        public static func isBuild(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }

        /// The cuts of a `0-4|4-32` cut string over `layerCount` layers; nil when it is not one.
        public static func cuts(_ cut: String, layerCount: Int) -> [Int]? {
            let ranges = cut.split(separator: "|").map { $0.split(separator: "-").compactMap { Int($0) } }
            guard ranges.count >= 2, ranges.allSatisfy({ $0.count == 2 && $0[0] < $0[1] }), ranges.first?[0] == 0,
                  ranges.last?[1] == layerCount, zip(ranges, ranges.dropFirst()).allSatisfy({ $0.0[1] == $0.1[0] }) else { return nil }
            return ranges.dropLast().map { $0[1] }
        }

        /// The cuts of a setup's cut string in `mode` over `ranks` ranks: a
        /// tensor-parallel setup names every rank `0-<layers>` and has none.
        public static func cuts(_ cut: String, layerCount: Int, mode: ClusterGenerationMode, ranks: Int) -> [Int]? {
            guard mode.usesTensorParallelPrefill else { return cuts(cut, layerCount: layerCount) }
            let ranges: String
            if cut.contains("@") {
                // Weighted: every rank names a weight, or the string is not one.
                guard tensorShares(cut) != nil else { return nil }
                ranges = cut.split(separator: "|").map { String($0.split(separator: "@")[0]) }.joined(separator: "|")
            } else {
                ranges = cut
            }
            return ranges == Self.cut([], layerCount: layerCount, mode: mode, ranks: ranks) ? [] : nil
        }

        /// A tensor-parallel setup with unequal shares names each rank's
        /// weight after its range (`0-64@1|0-64@3`), so that what it served
        /// is credited to the shares it ran at; equal shares name none.
        public static func cut(_ cuts: [Int], layerCount: Int, mode: ClusterGenerationMode, ranks: Int,
                               tensorShares: [Int]?) -> String {
            weighted(cut(cuts, layerCount: layerCount, mode: mode, ranks: ranks), mode: mode, tensorShares: tensorShares)
        }

        /// `cut` with each rank's weight appended when `mode` is tensor
        /// parallel and the weights are unequal (one per rank); `cut` otherwise.
        public static func weighted(_ cut: String, mode: ClusterGenerationMode, tensorShares: [Int]?) -> String {
            let ranges = cut.split(separator: "|")
            guard mode.usesTensorParallelPrefill, let tensorShares, Set(tensorShares).count > 1,
                  tensorShares.count == ranges.count, tensorShares.allSatisfy({ (1...64).contains($0) }),
                  !cut.contains("@") else { return cut }
            return zip(ranges, tensorShares).map { "\($0)@\($1)" }.joined(separator: "|")
        }

        /// The unequal share weights a tensor-parallel setup's cut names, rank
        /// order; nil for equal shares or a string that is not one.
        public static func tensorShares(_ cut: String) -> [Int]? {
            let parts = cut.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.split(separator: "@", omittingEmptySubsequences: false) }
            guard parts.count >= 2, parts.allSatisfy({ $0.count == 2 }) else { return nil }
            let weights = parts.compactMap { Int($0[1]) }
            guard weights.count == parts.count, weights.allSatisfy({ (1...64).contains($0) }), Set(weights).count > 1 else { return nil }
            return weights
        }

        /// `cut(_:layerCount:)`, or `0-64|0-64` for tensor parallel over two ranks.
        public static func cut(_ cuts: [Int], layerCount: Int, mode: ClusterGenerationMode, ranks: Int) -> String {
            guard mode.usesTensorParallelPrefill else { return cut(cuts, layerCount: layerCount) }
            return Array(repeating: "0-\(layerCount)", count: max(1, ranks)).joined(separator: "|")
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
              setup.cut.utf8.count <= 256, (setup.ranks ?? []).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 }),
              (setup.rankBuildSHA256 ?? []).count <= 8, (setup.rankBuildSHA256 ?? []).allSatisfy(Setup.isBuild) else { return }
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

    /// The entries a plan or a route for these worker builds may use, and how
    /// many others `entries` held. `builds` is each member's worker build
    /// (SHA-256 of its worker binary) by member ID, the builds the plan is
    /// for; an entry counts only when every rank ran its member's build
    /// (`Setup.servedBy`). A build changes the kernels a request runs, so what
    /// one build served says nothing of another's: on the M3 Ultra + M5 Max
    /// pair (2026-10-25) requests served by builds before c41, some while the
    /// M3 Ultra was busy, kept steering the 27B's plans, which stayed at 3:2
    /// where c41's own share probes balance it 1:1 (taken as c41's, they cut
    /// its predicted decode from 55.7 to 23.2 tok/s). A new build therefore
    /// plans without served speeds until it has served, as a share probe from
    /// another build starts its member again (`ClusterShareProbeHistory`). An
    /// entry written before builds were recorded counts as another build's.
    public static func servedBy(_ builds: [String: String], _ entries: [Entry]) -> (current: [Entry], otherBuilds: Int) {
        let current = entries.filter { $0.setup.servedBy(builds) }
        return (current, entries.count - current.count)
    }

    /// The plan's one line for `count` records left out because another worker
    /// build served them (`servedBy`); nil when there were none.
    public static func otherBuildsLine(_ count: Int, builds: [String: String]) -> String? {
        guard count > 0 else { return nil }
        let named = Set(builds.values).sorted().map { String($0.prefix(12)) }
        return "  \(count) record(s) from other worker builds ignored: a served speed counts only for the build that served it"
            + (named.isEmpty ? "" : " (this plan is for worker build\(named.count == 1 ? "" : "s") \(named.joined(separator: ", ")))")
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
        /// Tensor parallel with unequal shares: each rank's weight (rank
        /// order); nil for equal shares and every other mode.
        public let tensorShares: [Int]?
        public init(devices: [ClusterPlacementDevice], cuts: [Int], mode: ClusterGenerationMode,
                    schedule: ClusterPrefillSchedule, layout: ClusterModelLayout, link: ClusterLinkCosts = .unmeasured,
                    tensorShares: [Int]? = nil) {
            self.devices = devices; self.cuts = cuts; self.mode = mode; self.schedule = schedule
            self.layout = layout; self.link = link
            self.tensorShares = mode == .tensorParallel && (tensorShares.map { Set($0).count > 1 } ?? false) ? tensorShares : nil
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
    /// `plainDecodeTokensPerSecond` (a pipeline's speculative rounds only): the
    /// decode the same placement served without them; their speed-up is then
    /// the ratio of the two observations. Without it the rounds are credited
    /// nothing: a prediction of the plain decode is no measurement.
    public static func measurements(_ samples: [ClusterServedSample], placement: Placement,
                                    runtimeBinarySHA256: String, measuredUTC: String,
                                    plainDecodeTokensPerSecond: Double? = nil) throws -> [ClusterSpeedMeasurement] {
        let layout = placement.layout, devices = placement.devices
        let usable = samples.filter(\.valid)
        guard !usable.isEmpty, placement.cuts.count == placement.mode.layerCutCount(ranks: devices.count) else { return [] }
        if placement.mode.usesTensorParallelDecode {
            return try tensorParallelMeasurements(usable, placement: placement, runtimeBinarySHA256: runtimeBinarySHA256,
                measuredUTC: measuredUTC)
        }
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
        // A pipeline's speculative rounds say nothing about plain decode; their observed rate over what
        // the same placement served plainly is the speed-up the decoding rank is credited with, and
        // without a served plain rate they are credited nothing.
        let pipelineSpeculative = placement.mode.usesSpeculativeHead && !placement.mode.isPhaseSplit
        var decodeScales: [Double] = [], speculativeFactors: [Double] = []
        if !placement.mode.isPhaseSplit {
            for s in pair {
                guard let observed = s.decodeTokensPerSecond else { continue }
                if pipelineSpeculative {
                    if let plain = plainDecodeTokensPerSecond, plain.isFinite, plain > 0 {
                        speculativeFactors.append(observed / plain)
                    }
                }
                else { decodeScales.append(observed / (try pairPrediction(s).decodeTokensPerSecond)) }
            }
        }
        let decodeScale = median(decodeScales), speculativeFactor = median(speculativeFactors)
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
            var decode: Double?, speculative: Double?, pipelineFactor: Double?
            if let own {
                if head {
                    // The observed rate is with the head; the plain rate is the
                    // row's factor below it, or as fast when the row has none.
                    speculative = own; decode = own / max(1, layout.speculativeDecodeFactor ?? 1)
                } else { decode = own }
            } else if let speculativeFactor, device.label == decoder, device.speed.absolute {
                decode = base.decodeTokensPerSecond; pipelineFactor = speculativeFactor
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
                    speculativeDecodeTokensPerSecond: speculative, pipelineSpeculativeFactor: pipelineFactor),
                sustained: nil, measuredUTC: measuredUTC, provenance: how))
        }
        return result
    }

    /// A tensor-parallel setup's served requests correct each rank's shard
    /// rates, never its whole-model ones: the reductions are a measured cost
    /// of the link, so what the observed step differs from the predicted one
    /// by is the ranks' shares. Each device's predicted share step is scaled
    /// by (observed step - reductions) / (predicted step - reductions); the
    /// same for the shard prefill of `tensor_parallel_v1` by the first token
    /// (the hybrid's prefill is a pipeline's and corrects nothing here). A
    /// pair that served slower than predicted lowers the shard rates, and the
    /// next plan stops choosing tensor parallel where it no longer wins. The
    /// factor scales every share point a device has (its share probes), not
    /// only the served share's, so the ratio the probes measured between the
    /// ranks and between one rank's shares stands: one observed step cannot
    /// say which rank was the slower.
    static func tensorParallelMeasurements(_ usable: [ClusterServedSample], placement: Placement,
                                           runtimeBinarySHA256: String, measuredUTC: String) throws -> [ClusterSpeedMeasurement] {
        let layout = placement.layout, devices = placement.devices
        guard let tp = layout.tensorParallel, let reduction = placement.link.reduction else { return [] }
        let pair = usable.filter { $0.route == .pair }
        guard !pair.isEmpty else { return [] }
        var policy = ClusterPlacementPolicy()
        let reductionStep = tp.family.decodeReductionSeconds(layers: layout.layerCount, head: true, reduction: reduction)
        var decodeFactors: [Double] = [], prefillFactors: [Double] = []
        for s in pair {
            policy.promptTokens = s.promptTokens; policy.outputTokens = max(1, s.outputTokens)
            let predicted = try ClusterPlacementPlanner.evaluate(devices: devices, cuts: placement.cuts, mode: placement.mode,
                prefillSchedule: placement.schedule, layout: layout, policy: policy, link: placement.link,
                tensorShares: placement.tensorShares).rested
            if let observed = s.decodeTokensPerSecond {
                let compute = 1 / predicted.decodeTokensPerSecond - reductionStep
                if compute > 0 { decodeFactors.append(max(1e-6, 1 / observed - reductionStep) / compute) }
            }
            if placement.mode.usesTensorParallelPrefill {
                prefillFactors.append(s.firstTokenSeconds / predicted.firstTokenSeconds)
            }
        }
        let decodeFactor = median(decodeFactors), prefillFactor = median(prefillFactors)
        guard decodeFactor != nil || prefillFactor != nil else { return [] }
        let total = Double((placement.tensorShares ?? []).reduce(0, +))
        return try devices.enumerated().compactMap { index, device -> ClusterSpeedMeasurement? in
            guard device.speed.absolute else { return nil }
            let base = device.speed.rested
            // What the plan predicted for this rank: its shard probe, else its measured hardware (`ClusterHardwarePrior`).
            let split = ClusterDecodeSplit(rates: base,
                hardwareWeightSeconds: ClusterHardwarePrior.weightSeconds(profile: device.profile, layout: layout),
                hardwareDividedFraction: ClusterHardwarePrior.dividedDecodeFraction(layout))
            // Its prefill as the planner predicted it: a probe that timed decode only says nothing of prefill.
            let prefillFromHardware = ClusterDecodeSplit(rates: base.withoutDecodeOnlyShareRates,
                hardwareWeightSeconds: ClusterHardwarePrior.weightSeconds(profile: device.profile, layout: layout),
                hardwareDividedFraction: ClusterHardwarePrior.dividedDecodeFraction(layout)).fromHardware == true
            var shardDecode = base.tensorShardDecodeTokensPerSecond, shardPrefill = base.tensorShardPrefillTokensPerSecond
            // Every share point this Mac has, scaled as its served step is.
            var shareRates = base.tensorShareRates?.map { point in
                ClusterShareRate(sharePerMille: point.sharePerMille,
                    decodeTokensPerSecond: point.decodeTokensPerSecond / (decodeFactor ?? 1),
                    prefillTokensPerSecond: point.prefillTokensPerSecond.map { $0 / (prefillFactor ?? 1) })
            }
            if let weights = placement.tensorShares {
                // Unequal shares: what was served corrects this Mac's step at
                // its own share (a share rate), never the equal half's.
                let fraction = Double(weights[index]) / total
                // A probe at this share is scaled as every other point is, at its own share.
                let probed = base.shareRate(near: fraction)
                let perMille = probed?.sharePerMille ?? Int((fraction * 1000).rounded())
                let step = (probed.map { 1 / $0.decodeTokensPerSecond } ?? split.shareStepSeconds(fraction: fraction)) * (decodeFactor ?? 1)
                // As the planner predicted it: a probe at this share, the half's or another share's scaled, the
                // hardware prior (its share of every layer), else the whole model's rate.
                let prefillPerToken = (base.measuredSharePrefillSeconds(fraction: fraction, ranks: devices.count)
                    ?? (prefillFromHardware ? fraction / base.prefillTokensPerSecond : 1 / base.prefillTokensPerSecond))
                    * (prefillFactor ?? 1)
                let kept = (shareRates ?? []).filter { abs($0.sharePerMille - perMille) > 5 }.suffix(15)
                shareRates = Array(kept) + [ClusterShareRate(sharePerMille: perMille, decodeTokensPerSecond: 1 / step,
                    prefillTokensPerSecond: 1 / prefillPerToken)]
            } else {
                shardDecode = decodeFactor.map { 1 / (split.shareStepSeconds(ranks: devices.count) * $0) }
                    ?? base.tensorShardDecodeTokensPerSecond
                // As the planner predicted it (`measuredSharePrefillSeconds`), the hardware prior, else the whole model's.
                let equal = 1 / Double(devices.count)
                let predictedShardPrefill = base.shareRate(near: equal)?.prefillTokensPerSecond ?? base.tensorShardPrefillTokensPerSecond
                    ?? base.measuredSharePrefillSeconds(fraction: equal, ranks: devices.count).map { 1 / $0 }
                    ?? (prefillFromHardware ? base.prefillTokensPerSecond * Double(devices.count) : base.prefillTokensPerSecond)
                shardPrefill = prefillFactor.map { predictedShardPrefill / $0 } ?? base.tensorShardPrefillTokensPerSecond
            }
            let prompt = Int(median(pair.map { Double($0.promptTokens) }) ?? Double(layout.maximumChunkTokens))
            return try .init(key: .init(artifactSHA256: layout.artifactSHA256, chip: device.profile.chip,
                    osBuild: device.profile.osBuild, runtimeBinarySHA256: runtimeBinarySHA256,
                    probe: "served_\(placement.mode.rawValue)_v1"),
                promptTokens: max(1, prompt), chunkTokens: layout.maximumChunkTokens, probedLayers: layout.layerCount,
                layerCount: layout.layerCount,
                rested: .init(prefillTokensPerSecond: base.prefillTokensPerSecond, decodeTokensPerSecond: base.decodeTokensPerSecond,
                    speculativeDecodeTokensPerSecond: base.speculativeDecodeTokensPerSecond,
                    tensorShardPrefillTokensPerSecond: shardPrefill, tensorShardDecodeTokensPerSecond: shardDecode,
                    tensorShareRates: shareRates),
                sustained: nil, measuredUTC: measuredUTC,
                provenance: "shard rates derived from \(pair.count) request(s) the pair served (\(placement.mode.rawValue)"
                    + (placement.tensorShares.map { ", shares " + $0.map(String.init).joined(separator: ":") } ?? "")
                    + "); whole-model rates kept")
        }
    }

    /// Measurements from every setup `entries` name whose ranks are all among
    /// `devices` (labels) and whose cut fits `layout`, with one plain line per
    /// setup. The plan tool (`plan --served`) and the provider's planning use
    /// it the same way: the measurements join the others before the speeds
    /// are estimated, so the next plan starts from what was served. Callers
    /// pass only the entries the plan's worker builds served
    /// (`ClusterServedSpeedRecords.servedBy`); a setup is one build's, so
    /// samples of two builds are never one median.
    public static func measurements(entries: [ClusterServedSpeedRecords.Entry], devices: [ClusterPlacementDevice],
                                    layout: ClusterModelLayout, link: ClusterLinkCosts, measuredUTC: String) throws
        -> (measurements: [ClusterSpeedMeasurement], lines: [String]) {
        var measurements: [ClusterSpeedMeasurement] = [], lines: [String] = []
        var speculativeFactors: [(device: ClusterPlacementDevice, factor: Double)] = []
        var setups: [ClusterServedSpeedRecords.Setup] = []
        for entry in entries where !setups.contains(entry.setup) { setups.append(entry.setup) }
        for setup in setups {
            guard let ranks = setup.ranks, let mode = ClusterGenerationMode(rawValue: setup.mode),
                  let cuts = ClusterServedSpeedRecords.Setup.cuts(setup.cut, layerCount: layout.layerCount, mode: mode, ranks: ranks.count),
                  cuts.count == mode.layerCutCount(ranks: ranks.count) else {
                lines.append("  \(setup.mode) cut \(setup.cut): skipped (no rank order, or not this model's layers)")
                continue
            }
            let ordered = ranks.compactMap { label in devices.first { $0.label == label } }
            guard ordered.count == ranks.count else { lines.append("  \(setup.mode) cut \(setup.cut): skipped (a rank is not a planned device)"); continue }
            let samples = entries.filter { $0.setup == setup }.map(\.sample)
            let schedule: ClusterPrefillSchedule = layout.prefillSchedules.contains(.oneChunkLookahead) ? .oneChunkLookahead : .serial
            // A pipeline's speculative rounds are measured against what the same placement served plainly
            // with the same builds: their speed-up then rides on the decoding rank's plain measurement (one
            // record per device).
            if mode.usesSpeculativeHead, !mode.isPhaseSplit, let decoder = ordered.last {
                let plainSetup = ClusterServedSpeedRecords.Setup(modelID: setup.modelID, mode: ClusterGenerationMode.pipeline.rawValue,
                    cut: setup.cut, ranks: setup.ranks, rankBuildSHA256: setup.rankBuildSHA256)
                if let plain = median(entries.filter { $0.setup == plainSetup && $0.sample.route == .pair }.compactMap(\.sample.decodeTokensPerSecond)),
                   let rounds = median(samples.filter { $0.route == .pair }.compactMap(\.decodeTokensPerSecond)) {
                    speculativeFactors.append((decoder, rounds / plain))
                    lines.append("  \(setup.mode) cut \(setup.cut) (\(ranks.joined(separator: ", "))): \(samples.count) request(s) -> "
                        + String(format: "decode %.1f tok/s against %.1f served plainly: speed-up %.2f credited to %@", rounds, plain,
                                 rounds / plain, decoder.label))
                    continue
                }
            }
            // A weighted tensor-parallel setup is credited at its shares, when this model's plan offers them.
            let shares = mode == .tensorParallel ? ClusterServedSpeedRecords.Setup.tensorShares(setup.cut) : nil
            if let shares, !(layout.tensorParallel?.family.shareOptions ?? []).contains(shares) {
                lines.append("  \(setup.mode) cut \(setup.cut): skipped (shares this model's plan does not offer)")
                continue
            }
            let derived = try Self.measurements(samples,
                placement: .init(devices: ordered, cuts: cuts, mode: mode, schedule: schedule, layout: layout, link: link,
                    tensorShares: shares),
                runtimeBinarySHA256: "served", measuredUTC: measuredUTC)
            measurements += derived
            let pair = samples.filter { $0.route == .pair }.count
            lines.append("  \(setup.mode) cut \(setup.cut) (\(ranks.joined(separator: ", "))): \(pair) pair and \(samples.count - pair) alone request(s)"
                + " -> " + (derived.isEmpty ? "nothing usable" : derived.map { m in
                    let label = devices.first { $0.profile.chip == m.key.chip && $0.profile.osBuild == m.key.osBuild }?.label ?? m.key.chip
                    return String(format: "%@ prefill %.0f tok/s, decode %.1f tok/s", label, m.rested.prefillTokensPerSecond,
                        m.rested.speculativeDecodeTokensPerSecond ?? m.rested.decodeTokensPerSecond)
                }.joined(separator: "; ")))
        }
        for (device, factor) in speculativeFactors where factor.isFinite && factor > 0 {
            let plainProbe = "served_\(ClusterGenerationMode.pipeline.rawValue)_v1"
            let same = { (m: ClusterSpeedMeasurement) in m.key.chip == device.profile.chip && m.key.osBuild == device.profile.osBuild }
            if let index = measurements.lastIndex(where: { same($0) && $0.key.probe == plainProbe }) {
                let m = measurements[index]
                measurements[index] = try .init(key: m.key, promptTokens: m.promptTokens, chunkTokens: m.chunkTokens,
                    probedLayers: m.probedLayers, layerCount: m.layerCount,
                    rested: .init(prefillTokensPerSecond: m.rested.prefillTokensPerSecond,
                        decodeTokensPerSecond: m.rested.decodeTokensPerSecond,
                        speculativeDecodeTokensPerSecond: m.rested.speculativeDecodeTokensPerSecond,
                        pipelineSpeculativeFactor: factor),
                    sustained: m.sustained, hashBytesPerSecond: m.hashBytesPerSecond,
                    materializeBytesPerSecond: m.materializeBytesPerSecond, measuredUTC: m.measuredUTC,
                    provenance: m.provenance + String(format: "; pipeline speculative rounds served %.2fx this placement's plain decode", factor))
            }
        }
        return (measurements, lines)
    }
}
