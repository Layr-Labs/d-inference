import Foundation

/// Two rates for a whole model on one device alone.
public struct ClusterSpeedRates: Codable, Equatable, Sendable {
    public let prefillTokensPerSecond: Double
    public let decodeTokensPerSecond: Double
    public init(prefillTokensPerSecond: Double, decodeTokensPerSecond: Double) {
        self.prefillTokensPerSecond = prefillTokensPerSecond; self.decodeTokensPerSecond = decodeTokensPerSecond
    }
    var valid: Bool {
        prefillTokensPerSecond.isFinite && prefillTokensPerSecond > 0
            && decodeTokensPerSecond.isFinite && decodeTokensPerSecond > 0
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
public struct ClusterSpeedMeasurement: Codable, Equatable, Sendable {
    public static let schemaName = "darkbloom_cluster_speed_measurement_v1"
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
        schema = Self.schemaName; self.key = key; self.promptTokens = promptTokens; self.chunkTokens = chunkTokens
        self.probedLayers = probedLayers; self.layerCount = layerCount; self.rested = rested
        self.sustained = sustained; self.hashBytesPerSecond = hashBytesPerSecond
        self.materializeBytesPerSecond = materializeBytesPerSecond; self.measuredUTC = measuredUTC; self.provenance = provenance
        try validate()
    }

    public func validate() throws {
        guard schema == Self.schemaName, promptTokens > 0, chunkTokens > 0, layerCount > 0,
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

    public init(measured: Bool, perChunkSeconds: Double, perDecodeStepSeconds: [String: Double],
                handoffSecondsPerByte: Double, provenance: String) {
        self.measured = measured; self.perChunkSeconds = perChunkSeconds
        self.perDecodeStepSeconds = perDecodeStepSeconds; self.handoffSecondsPerByte = handoffSecondsPerByte
        self.provenance = provenance
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
        func latest(_ subject: Subject, artifact: String) -> ClusterSpeedMeasurement? {
            func distance(_ m: ClusterSpeedMeasurement) -> Double {
                promptTokens.map { abs(log(Double(m.promptTokens) / Double(max(1, $0)))) } ?? 0
            }
            return measurements.filter {
                $0.key.artifactSHA256 == artifact && $0.key.chip == subject.chip && $0.key.osBuild == subject.osBuild
                    && (runtimeBinarySHA256 == nil || $0.key.runtimeBinarySHA256 == runtimeBinarySHA256)
            }.min { a, b in
                distance(a) != distance(b) ? distance(a) < distance(b) : a.measuredUTC > b.measuredUTC
            }
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
                return .init(source: .assumedEqual, absolute: false, rested: m.rested, sustained: m.sustained,
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
