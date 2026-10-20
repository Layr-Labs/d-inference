import DarkbloomClusterProtocol
import Foundation

/// Two rates for a whole model on one device alone, and, when measured, the
/// decode rate of the same device running the model's speculative head.
/// A tensor-parallel shard probe at one share of the model (a rank holding
/// `sharePerMille` / 1000 of every divided part, no reduction), measured on
/// the device itself: a share's step is not a straight line between the
/// whole and a half on every chip (measured 2026-10-14 on an M3 Ultra, 27B:
/// whole 26.1 ms, half 24.7 ms, quarter 16.3 ms).
public struct ClusterShareRate: Codable, Equatable, Sendable {
    public let sharePerMille: Int
    public let decodeTokensPerSecond: Double
    public let prefillTokensPerSecond: Double?
    public init(sharePerMille: Int, decodeTokensPerSecond: Double, prefillTokensPerSecond: Double? = nil) {
        self.sharePerMille = sharePerMille; self.decodeTokensPerSecond = decodeTokensPerSecond
        self.prefillTokensPerSecond = prefillTokensPerSecond
    }
    var valid: Bool {
        (1...999).contains(sharePerMille) && decodeTokensPerSecond.isFinite && decodeTokensPerSecond > 0
            && (prefillTokensPerSecond.map { $0.isFinite && $0 > 0 } ?? true)
    }
}

public struct ClusterSpeedRates: Codable, Equatable, Sendable {
    public let prefillTokensPerSecond: Double
    public let decodeTokensPerSecond: Double
    /// Decode with the model's own speculative (MTP) head, measured on this
    /// device (a staged reference's MTP run). Nil when not measured; never
    /// transferred from another device, since the head's gain is the chip's own.
    public let speculativeDecodeTokensPerSecond: Double?
    /// Prefill and decode of an equal half of every layer on this device
    /// alone, with no reduction (the tensor-parallel shard probe): what a rank
    /// of `tensor_parallel_v1` computes between reductions. Nil when not
    /// measured; never transferred from another device, since how much of a
    /// step shrinks with the weights is the chip's own (`ClusterDecodeSplit`).
    public let tensorShardPrefillTokensPerSecond: Double?
    public let tensorShardDecodeTokensPerSecond: Double?
    /// The decode speed-up a pipeline's speculative rounds (`pipeline_mtp_v1`)
    /// served with this device as the decoding rank: what one placement served
    /// with the rounds over what the same placement served plainly
    /// (`ClusterServedCalibration`). A separate figure from
    /// `speculativeDecodeTokensPerSecond`: every rank verifies a pipeline's
    /// window, so neither says anything about the other. Nil when not served;
    /// never transferred from another device.
    public let pipelineSpeculativeFactor: Double?
    /// Shard probes at other shares (unequal tensor-parallel splits), the
    /// device's own; nil when none was measured.
    public let tensorShareRates: [ClusterShareRate]?
    public init(prefillTokensPerSecond: Double, decodeTokensPerSecond: Double,
                speculativeDecodeTokensPerSecond: Double? = nil, pipelineSpeculativeFactor: Double? = nil,
                tensorShardPrefillTokensPerSecond: Double? = nil, tensorShardDecodeTokensPerSecond: Double? = nil,
                tensorShareRates: [ClusterShareRate]? = nil) {
        self.prefillTokensPerSecond = prefillTokensPerSecond; self.decodeTokensPerSecond = decodeTokensPerSecond
        self.speculativeDecodeTokensPerSecond = speculativeDecodeTokensPerSecond
        self.pipelineSpeculativeFactor = pipelineSpeculativeFactor
        self.tensorShardPrefillTokensPerSecond = tensorShardPrefillTokensPerSecond
        self.tensorShardDecodeTokensPerSecond = tensorShardDecodeTokensPerSecond
        self.tensorShareRates = tensorShareRates?.isEmpty == true ? nil : tensorShareRates
    }

    /// A measured shard probe within 5 per mille of `fraction`, if any.
    public func shareRate(near fraction: Double) -> ClusterShareRate? {
        (tensorShareRates ?? []).min { abs(Double($0.sharePerMille) / 1000 - fraction) < abs(Double($1.sharePerMille) / 1000 - fraction) }
            .flatMap { abs(Double($0.sharePerMille) / 1000 - fraction) <= 0.005 ? $0 : nil }
    }
    var valid: Bool {
        prefillTokensPerSecond.isFinite && prefillTokensPerSecond > 0
            && decodeTokensPerSecond.isFinite && decodeTokensPerSecond > 0
            && [speculativeDecodeTokensPerSecond, pipelineSpeculativeFactor, tensorShardPrefillTokensPerSecond,
                tensorShardDecodeTokensPerSecond].allSatisfy { $0.map { $0.isFinite && $0 > 0 } ?? true }
            && (tensorShareRates ?? []).allSatisfy(\.valid) && (tensorShareRates ?? []).count <= 16
    }
    /// True when a figure beyond the plain two rates is present (schema v2):
    /// a speculative rate, the served pipeline speed-up or a shard rate.
    var extended: Bool {
        speculativeDecodeTokensPerSecond != nil || pipelineSpeculativeFactor != nil
            || tensorShardPrefillTokensPerSecond != nil || tensorShardDecodeTokensPerSecond != nil
            || tensorShareRates != nil
    }
    /// True when either speculative figure is present.
    var carriesSpeculative: Bool { speculativeDecodeTokensPerSecond != nil || pipelineSpeculativeFactor != nil }
    /// The same rates without the speculative and shard ones: what may be
    /// said of another device scaled from these.
    var withoutSpeculative: ClusterSpeedRates {
        .init(prefillTokensPerSecond: prefillTokensPerSecond, decodeTokensPerSecond: decodeTokensPerSecond)
    }
}

/// What a cached measurement is a measurement of. Two measurements with one
/// key are the same experiment; anything that could change the result is in it.
public struct ClusterSpeedKey: Codable, Hashable, Sendable {
    public let artifactSHA256: String
    public let chip: String
    public let osBuild: String
    public let runtimeBinarySHA256: String
    /// The probe's shape, for example `stage0_cut4_prompt2048_chunk512_decode16_v1`.
    public let probe: String
    public init(artifactSHA256: String, chip: String, osBuild: String, runtimeBinarySHA256: String, probe: String) {
        self.artifactSHA256 = artifactSHA256; self.chip = chip; self.osBuild = osBuild
        self.runtimeBinarySHA256 = runtimeBinarySHA256; self.probe = probe
    }
}

/// The result of a speed probe on one device: what any family's probe reports,
/// in these units, whatever it ran to obtain them.
///
/// A probe loads part of a model through the verified loader, runs a prompt
/// through it and a few decode steps, and scales to the whole model by the
/// layout's layer cost share. `rested` is the first repetition on a Mac that
/// was idle; `sustained` is the rate the repetitions settle at. A probe that
/// ran once reports no sustained figure, and the planner says it used a
/// rested one.
///
/// Schema v2 adds optional figures per regime: decode with the model's
/// speculative head, the served pipeline speed-up (`pipelineSpeculativeFactor`),
/// and prefill and decode of a tensor-parallel shard; a record without any is
/// written as v1, byte for byte as before, and a v1 record still loads.
public struct ClusterSpeedMeasurement: Codable, Equatable, Sendable {
    public static let schemaName = "darkbloom_cluster_speed_measurement_v1"
    public static let schemaNameV2 = "darkbloom_cluster_speed_measurement_v2"
    public let schema: String
    public let key: ClusterSpeedKey
    /// Prompt length and chunk size the prefill rate was measured at.
    public let promptTokens: Int
    public let chunkTokens: Int
    /// Layers the probe ran, of how many. Equal when the whole model ran.
    public let probedLayers: Int
    public let layerCount: Int
    public let rested: ClusterSpeedRates
    public let sustained: ClusterSpeedRates?
    /// The verified loader's two rates on this device: artifact bytes hashed
    /// per second (every rank hashes the whole artifact before it loads) and
    /// weight bytes materialized per second. Startup budgets are derived from
    /// these. Release has not been timed by any probe yet.
    public let hashBytesPerSecond: Double?
    public let materializeBytesPerSecond: Double?
    public let measuredUTC: String
    /// Where the figures came from, in plain words.
    public let provenance: String

    public init(key: ClusterSpeedKey, promptTokens: Int, chunkTokens: Int, probedLayers: Int, layerCount: Int,
                rested: ClusterSpeedRates, sustained: ClusterSpeedRates?, hashBytesPerSecond: Double? = nil,
                materializeBytesPerSecond: Double? = nil, measuredUTC: String, provenance: String) throws {
        let speculative = rested.extended || (sustained?.extended ?? false)
        schema = speculative ? Self.schemaNameV2 : Self.schemaName
        self.key = key; self.promptTokens = promptTokens; self.chunkTokens = chunkTokens
        self.probedLayers = probedLayers; self.layerCount = layerCount; self.rested = rested
        self.sustained = sustained; self.hashBytesPerSecond = hashBytesPerSecond
        self.materializeBytesPerSecond = materializeBytesPerSecond; self.measuredUTC = measuredUTC; self.provenance = provenance
        try validate()
    }

    /// True for what a tensor-parallel setup served (`ClusterServedCalibration`):
    /// its shard rates are measured, its whole-model rates are not.
    public var correctsShardRatesOnly: Bool {
        let probe = key.probe
        guard probe.hasPrefix("served_"), probe.hasSuffix("_v1"),
              let mode = ClusterGenerationMode(rawValue: String(probe.dropFirst(7).dropLast(3))) else { return false }
        return mode.usesTensorParallelDecode
    }

    /// This measurement with `other`'s shard rates (equal half and other
    /// shares) in place of its own.
    func withShardRates(of other: ClusterSpeedMeasurement) throws -> ClusterSpeedMeasurement {
        func merged(_ a: ClusterSpeedRates, _ b: ClusterSpeedRates) -> ClusterSpeedRates {
            .init(prefillTokensPerSecond: a.prefillTokensPerSecond, decodeTokensPerSecond: a.decodeTokensPerSecond,
                speculativeDecodeTokensPerSecond: a.speculativeDecodeTokensPerSecond,
                pipelineSpeculativeFactor: a.pipelineSpeculativeFactor,
                tensorShardPrefillTokensPerSecond: b.tensorShardPrefillTokensPerSecond ?? a.tensorShardPrefillTokensPerSecond,
                tensorShardDecodeTokensPerSecond: b.tensorShardDecodeTokensPerSecond ?? a.tensorShardDecodeTokensPerSecond,
                tensorShareRates: b.tensorShareRates ?? a.tensorShareRates)
        }
        return try .init(key: key, promptTokens: promptTokens, chunkTokens: chunkTokens, probedLayers: probedLayers,
            layerCount: layerCount, rested: merged(rested, other.rested), sustained: sustained.map { merged($0, other.rested) },
            hashBytesPerSecond: hashBytesPerSecond, materializeBytesPerSecond: materializeBytesPerSecond,
            measuredUTC: measuredUTC, provenance: String((provenance + "; shard rates as a tensor-parallel setup served").prefix(1024)))
    }

    public func validate() throws {
        // A v1 record cannot carry a speculative, served-speed-up or shard figure; a v2 record may.
        let speculative = rested.extended || (sustained?.extended ?? false)
        guard schema == Self.schemaNameV2 || (schema == Self.schemaName && !speculative),
              promptTokens > 0, chunkTokens > 0, layerCount > 0,
              (1...layerCount).contains(probedLayers), rested.valid, sustained?.valid ?? true,
              hashBytesPerSecond.map({ $0.isFinite && $0 > 0 }) ?? true,
              materializeBytesPerSecond.map({ $0.isFinite && $0 > 0 }) ?? true,
              provenance.utf8.count <= 1024, measuredUTC.utf8.count <= 64 else {
            throw ClusterPlacementError("Speed measurement is malformed")
        }
    }
}

/// A model-free index of one device, from a short benchmark of prefill-shaped
/// and decode-shaped work. Only ratios between devices mean anything.
public struct ClusterDeviceIndex: Codable, Equatable, Sendable {
    public let chip: String
    public let osBuild: String
    public let benchmark: String
    public let prefillIndex: Double
    public let decodeIndex: Double
    public init(chip: String, osBuild: String, benchmark: String, prefillIndex: Double, decodeIndex: Double) {
        self.chip = chip; self.osBuild = osBuild; self.benchmark = benchmark
        self.prefillIndex = prefillIndex; self.decodeIndex = decodeIndex
    }

    /// An index from another Mac is untrusted input: plain bounded labels and
    /// finite positive rates.
    public func validate() throws {
        func label(_ value: String, _ limit: Int) -> Bool {
            !value.isEmpty && value.utf8.count <= limit && value.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value < 127 }
        }
        guard label(chip, 96), label(osBuild, 32), label(benchmark, 64),
              [prefillIndex, decodeIndex].allSatisfy({ $0.isFinite && $0 > 0 && $0 < 1e15 }) else {
            throw ClusterPlacementError("Device index is malformed")
        }
    }
}

/// What the planner is told about one device's speed on one model, and how
/// much that is worth. Shown with its source wherever a prediction is shown.
public struct ClusterDeviceSpeed: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable, Comparable {
        /// A probe of this model on this chip, OS build and binary.
        case measured
        /// An estimate: another device's measurement of this model, scaled
        /// by a ratio measured for the same two devices on another model.
        case transferredByMeasuredRatio
        /// An estimate: scaled by the model-free device index.
        case transferredByDeviceIndex
        /// Nothing is known; the devices are assumed equal.
        case assumedEqual

        var rank: Int {
            switch self {
            case .measured: 0
            case .transferredByMeasuredRatio: 1
            case .transferredByDeviceIndex: 2
            case .assumedEqual: 3
            }
        }
        public static func < (a: Source, b: Source) -> Bool { a.rank < b.rank }
        public var isEstimate: Bool { self != .measured }
    }

    public let source: Source
    /// False when the rates are meaningful only as a ratio between devices.
    public let absolute: Bool
    public let rested: ClusterSpeedRates
    /// Nil when no settled rate is known.
    public let sustained: ClusterSpeedRates?
    public let hashBytesPerSecond: Double?
    public let materializeBytesPerSecond: Double?
    /// Prompt length the prefill rate holds at, when measured.
    public let promptTokens: Int?
    public let explanation: String

    public init(source: Source, absolute: Bool, rested: ClusterSpeedRates, sustained: ClusterSpeedRates?,
                hashBytesPerSecond: Double? = nil, materializeBytesPerSecond: Double? = nil,
                promptTokens: Int? = nil, explanation: String) {
        self.source = source; self.absolute = absolute; self.rested = rested; self.sustained = sustained
        self.hashBytesPerSecond = hashBytesPerSecond; self.materializeBytesPerSecond = materializeBytesPerSecond
        self.promptTokens = promptTokens; self.explanation = explanation
    }

    public static let assumedEqual = ClusterDeviceSpeed(source: .assumedEqual, absolute: false,
        rested: .init(prefillTokensPerSecond: 1, decodeTokensPerSecond: 1), sustained: nil,
        explanation: "no measurement of this model on this Mac; assumed equal to the other")
}

/// Link and protocol costs of one transport and mode: properties of the cable
/// and the framing, not of a model or a Mac. Measured across the link.
public struct ClusterLinkCosts: Codable, Equatable, Sendable {
    public let measured: Bool
    /// Added to the first token per prompt chunk and hop.
    public let perChunkSeconds: Double
    /// Added to every decode step, by generation mode.
    public let perDecodeStepSeconds: [String: Double]
    /// Hand-off after the first token under a phase split: seconds per byte of state.
    public let handoffSecondsPerByte: Double
    public let provenance: String
    /// One reduction of two ranks' tensor-parallel partials, when measured
    /// (`ClusterReductionCost`). Nil: no tensor-parallel mode is predicted.
    public let reduction: ClusterReductionCost?

    public init(measured: Bool, perChunkSeconds: Double, perDecodeStepSeconds: [String: Double],
                handoffSecondsPerByte: Double, provenance: String, reduction: ClusterReductionCost? = nil) {
        self.measured = measured; self.perChunkSeconds = perChunkSeconds
        self.perDecodeStepSeconds = perDecodeStepSeconds; self.handoffSecondsPerByte = handoffSecondsPerByte
        self.provenance = provenance; self.reduction = reduction
    }

    public static let unmeasured = ClusterLinkCosts(measured: false, perChunkSeconds: 0, perDecodeStepSeconds: [:],
        handoffSecondsPerByte: 0, provenance: "not measured: transfers are counted as free, so pipeline decode is an upper bound")
}

/// Turns what has been measured into one speed per device, most trusted
/// source first: this model on this device; this model on another device
/// scaled by a ratio measured for the two devices on another model; the same
/// scaled by the model-free index; and, with nothing at all, equal devices.
public enum ClusterSpeedEstimator {
    public struct Subject: Equatable, Sendable {
        public let chip: String
        public let osBuild: String
        public init(chip: String, osBuild: String) { self.chip = chip; self.osBuild = osBuild }
    }

    /// `promptTokens` is the reference request's prompt length: a prefill rate
    /// depends on it, so the measurement taken nearest to it is used, the
    /// latest when two are equally near.
    public static func estimate(devices: [Subject], artifactSHA256: String, runtimeBinarySHA256: String? = nil,
                                promptTokens: Int? = nil,
                                measurements: [ClusterSpeedMeasurement], indices: [ClusterDeviceIndex] = []) -> [ClusterDeviceSpeed] {
        // A tensor-parallel setup's served requests correct only that setup's
        // shard rates (`ClusterServedCalibration`); the whole-model rates they
        // carry are the estimate the correction started from. So they never
        // outrank another measurement's whole-model rates (a probe's, or what a
        // pipeline or a lone Mac served): the device takes the best of those,
        // with the served shard rates on top.
        func latest(_ subject: Subject, artifact: String) -> ClusterSpeedMeasurement? {
            func distance(_ m: ClusterSpeedMeasurement) -> Double {
                promptTokens.map { abs(log(Double(m.promptTokens) / Double(max(1, $0)))) } ?? 0
            }
            func best(_ candidates: [ClusterSpeedMeasurement]) -> ClusterSpeedMeasurement? {
                candidates.min { a, b in
                    distance(a) != distance(b) ? distance(a) < distance(b) : a.measuredUTC > b.measuredUTC
                }
            }
            let candidates = measurements.filter {
                $0.key.artifactSHA256 == artifact && $0.key.chip == subject.chip && $0.key.osBuild == subject.osBuild
                    && (runtimeBinarySHA256 == nil || $0.key.runtimeBinarySHA256 == runtimeBinarySHA256)
            }
            let wholeModel = best(candidates.filter { !$0.correctsShardRatesOnly })
            guard let shard = best(candidates.filter(\.correctsShardRatesOnly)) else { return wholeModel }
            guard let wholeModel else { return shard }
            return (try? wholeModel.withShardRates(of: shard)) ?? wholeModel
        }
        let own = devices.map { latest($0, artifact: artifactSHA256) }
        // A ratio between two devices, from the most trusted source that has one.
        func ratio(_ a: Subject, over b: Subject) -> (prefill: Double, decode: Double, source: ClusterDeviceSpeed.Source, note: String)? {
            if a == b { return (1, 1, .transferredByMeasuredRatio, "the same chip and OS build") }
            let others = Set(measurements.map(\.key.artifactSHA256)).subtracting([artifactSHA256]).sorted()
            for other in others {
                if let x = latest(a, artifact: other), let y = latest(b, artifact: other) {
                    return (x.rested.prefillTokensPerSecond / y.rested.prefillTokensPerSecond,
                            x.rested.decodeTokensPerSecond / y.rested.decodeTokensPerSecond,
                            .transferredByMeasuredRatio, "the ratio measured for these two Macs on another model")
                }
            }
            if let x = indices.first(where: { $0.chip == a.chip && $0.osBuild == a.osBuild }),
               let y = indices.first(where: { $0.chip == b.chip && $0.osBuild == b.osBuild && $0.benchmark == x.benchmark }),
               x.prefillIndex > 0, y.prefillIndex > 0, x.decodeIndex > 0, y.decodeIndex > 0 {
                return (x.prefillIndex / y.prefillIndex, x.decodeIndex / y.decodeIndex,
                        .transferredByDeviceIndex, "the model-free device index (\(x.benchmark))")
            }
            return nil
        }
        // A speculative rate is never scaled to another device: the head's gain
        // depends on the chip (it lost on the M3 Ultra and won on the M5 Max).
        func scaled(_ rates: ClusterSpeedRates, _ r: (prefill: Double, decode: Double, source: ClusterDeviceSpeed.Source, note: String)) -> ClusterSpeedRates {
            .init(prefillTokensPerSecond: rates.prefillTokensPerSecond * r.prefill,
                  decodeTokensPerSecond: rates.decodeTokensPerSecond * r.decode)
        }
        // The reference a device without its own measurement is scaled from.
        let reference = own.firstIndex(where: { $0 != nil })
        return devices.indices.map { index -> ClusterDeviceSpeed in
            if let m = own[index] {
                return .init(source: .measured, absolute: true, rested: m.rested, sustained: m.sustained,
                    hashBytesPerSecond: m.hashBytesPerSecond, materializeBytesPerSecond: m.materializeBytesPerSecond,
                    promptTokens: m.promptTokens, explanation: "measured at \(m.promptTokens) prompt tokens: " + m.provenance)
            }
            if let reference, let m = own[reference], let r = ratio(devices[index], over: devices[reference]) {
                return .init(source: r.source, absolute: true, rested: scaled(m.rested, r),
                    sustained: m.sustained.map { scaled($0, r) }, promptTokens: m.promptTokens,
                    explanation: "estimate: the other Mac's measurement scaled by " + r.note)
            }
            if let reference, let m = own[reference] {
                // Nothing relates this device to the measured one.
                return .init(source: .assumedEqual, absolute: false, rested: m.rested.withoutSpeculative,
                    sustained: m.sustained?.withoutSpeculative,
                    explanation: "no measurement on this Mac and nothing to scale by; assumed equal to the measured Mac")
            }
            // No device has measured this model: only ratios can be known.
            // Two Macs of one chip and OS build are equal by assumption, not by a ratio.
            if index > 0, devices[index] != devices[0], let r = ratio(devices[index], over: devices[0]) {
                return .init(source: r.source, absolute: false,
                    rested: .init(prefillTokensPerSecond: r.prefill, decodeTokensPerSecond: r.decode), sustained: nil,
                    explanation: "estimate: relative to the first Mac by " + r.note + "; this model's own speed is unknown")
            }
            if index == 0, devices.count > 1, devices[1] != devices[0], let r = ratio(devices[1], over: devices[0]) {
                return .init(source: r.source, absolute: false,
                    rested: .init(prefillTokensPerSecond: 1, decodeTokensPerSecond: 1), sustained: nil,
                    explanation: "estimate: the reference for " + r.note + "; this model's own speed is unknown")
            }
            return .assumedEqual
        }
    }
}

extension ClusterLinkCosts {
    /// The link costs a pair's latest link probe gives (`ClusterWorkerLinkProbe`,
    /// measured at load as the sharded modes use the link): the reduction is
    /// the all-sum's fixed part and per-byte slope between its small and large
    /// measurements (keyed when the probe's all-sums were sealed); a pipeline
    /// decode step pays two one-way small records (the step's hand-off and the
    /// token back), or `servedPipelineStepSeconds` when the pair served the
    /// pipeline and its owner derived the step's link share from that; a
    /// prefill chunk's hop one large record; a hand-off the records' per-byte
    /// slope. Nil for a malformed probe. Nothing here is per chip or per model.
    public init?(probe: ClusterWorkerLinkProbe, measuredUTC: String, servedPipelineStepSeconds: Double? = nil) {
        guard probe.valid, servedPipelineStepSeconds.map({ $0.isFinite && $0 >= 0 && $0 < 10 }) ?? true else { return nil }
        let us = 1e-6
        let slope = max(0, Double(probe.allSumLargeMicroseconds - probe.allSumSmallMicroseconds) * us
            / Double(probe.allSumLargeBytes - probe.allSumSmallBytes))
        let fixed = max(0, Double(probe.allSumSmallMicroseconds) * us - Double(probe.allSumSmallBytes) * slope)
        let recordSlope = max(0, Double(probe.pointToPointLargeMicroseconds - probe.pointToPointSmallMicroseconds) * us
            / Double(probe.pointToPointLargeBytes - probe.pointToPointSmallBytes))
        let step = servedPipelineStepSeconds ?? 2 * Double(probe.pointToPointSmallMicroseconds) * us
        let provenance = "measured at load over \(probe.transport) (\(probe.keyed ? "keyed, sealed all-sums" : "plaintext"))"
            + " at \(measuredUTC): all-sum \(probe.allSumSmallMicroseconds) us at \(probe.allSumSmallBytes) B and"
            + " \(probe.allSumLargeMicroseconds) us at \(probe.allSumLargeBytes) B; records \(probe.pointToPointSmallMicroseconds) us"
            + " at \(probe.pointToPointSmallBytes) B and \(probe.pointToPointLargeMicroseconds) us at \(probe.pointToPointLargeBytes) B"
            + (servedPipelineStepSeconds == nil ? "" : "; pipeline step from served requests")
        self.init(measured: true, perChunkSeconds: Double(probe.pointToPointLargeMicroseconds) * us,
            perDecodeStepSeconds: Dictionary(uniqueKeysWithValues: ClusterGenerationMode.allCases
                .filter { !$0.usesTensorParallelPrefill }.map { ($0.rawValue, step) }),
            handoffSecondsPerByte: recordSlope, provenance: String(provenance.prefix(1024)),
            reduction: .init(fixedSeconds: fixed, secondsPerByte: slope, keyed: probe.keyed, provenance: String(provenance.prefix(1024))))
    }
}
