import DarkbloomClusterProtocol
import Foundation

/// Which way one request goes, and why: the whole setup (`pair`), or the
/// fastest member that already holds the whole model, alone.
public struct ClusterRequestRoute: Codable, Equatable, Sendable {
    public enum Basis: String, Codable, Sendable {
        /// The planner's prediction from profiles and measurements.
        case predicted
        /// The prediction corrected by requests this route served at a similar prompt length.
        case served
    }

    public let path: ClusterServedSample.Route
    /// The member that serves alone; nil for the pair.
    public let member: String?
    /// The member that could serve alone, whichever path was taken; nil when none holds the whole model.
    public let aloneCandidate: String?
    public let promptTokens: Int
    public let outputTokens: Int
    public let pairSeconds: Double
    public let pairFirstTokenSeconds: Double
    public let pairBasis: Basis
    public let aloneSeconds: Double?
    public let aloneFirstTokenSeconds: Double?
    public let aloneBasis: Basis?
    /// In plain words.
    public let reason: String
    /// The pair serves this request to be measured near its length once (`Setup.measuresPair`).
    public var measuring = false

    /// `pair` or `alone:<member>`, as telemetry and status print it.
    public var label: String { member.map { "alone:" + $0 } ?? "pair" }
    /// What the reservation tells both ranks: nil for the pair as placed.
    public var workerRoute: ClusterWorkerRoute? { path == .alone ? .decodingRankAlone : nil }
}

/// Decides, for one request, whether the setup serves it as placed or the
/// fastest member that already holds every layer serves it alone, from the
/// planner's prediction for that request's prompt length, corrected by what
/// each route measurably served. Universal: the eligible member and both
/// times are derived from the placement, the devices' profiles and speed
/// records, and the model's layout; nothing names a chip, a model or a Mac.
///
/// Lossless: both routes are qualified paths. The pair runs the placement
/// its plan (and any qualification record) admitted; the member alone runs
/// the whole model on one chip, which is that Mac's single-Mac reference
/// computation. A member serves alone only when it already holds the whole
/// model (the decoding rank of a phase split loads every layer); a placement
/// no member holds whole (a model only the pair has room for) always goes to
/// the pair. The pair is chosen only when it is predicted faster than the
/// member alone by more than the tie tolerance, so a strong single Mac is
/// never made slower by its pair.
public enum ClusterRequestRouter {
    public struct Setup: Sendable {
        /// Rank order, as placed.
        public let devices: [ClusterPlacementDevice]
        public let cuts: [Int]
        public let mode: ClusterGenerationMode
        public let schedule: ClusterPrefillSchedule
        public let layout: ClusterModelLayout
        public let link: ClusterLinkCosts
        public let regime: ClusterPlacementPolicy.Regime
        /// The pair must be predicted faster than this share to be chosen.
        public let tieTolerance: Double
        /// Until both routes served requests near a prompt length (within a
        /// factor of two), the pair must be predicted faster than this share:
        /// a prediction only (the speed index, a whole-model rate stretched to
        /// another length) never makes a request slower than the member alone
        /// on a small margin. The member alone serves meanwhile, which measures
        /// it there.
        public let unmeasuredMargin: Double
        /// Whether the pair is measured once near a prompt length where the
        /// member alone was measured and the pair is still predicted faster
        /// beyond the tie tolerance (one request per factor-of-two band of
        /// prompt lengths per serving router): without it a pair that is
        /// faster only by less than `unmeasuredMargin` is never measured, and
        /// so never used. False keeps every request on the member alone
        /// until the pair is predicted faster by the larger margin.
        public let measuresPair: Bool
        /// The per-request alone route, kept but off by default (owner,
        /// 2026-10-13: sharded deployments only). Only the explicit hand-off
        /// opt-in (`DARKBLOOM_CLUSTER_HANDOFF_MODES=1` in the provider) turns it
        /// on; off, every request uses the cluster as placed.
        public let aloneRoute: Bool
        public init(devices: [ClusterPlacementDevice], cuts: [Int], mode: ClusterGenerationMode, schedule: ClusterPrefillSchedule,
                    layout: ClusterModelLayout, link: ClusterLinkCosts = .unmeasured,
                    regime: ClusterPlacementPolicy.Regime = .rested, tieTolerance: Double = 0.03, unmeasuredMargin: Double = 0.25,
                    measuresPair: Bool = true, aloneRoute: Bool = false) {
            self.devices = devices; self.cuts = cuts; self.mode = mode; self.schedule = schedule; self.layout = layout
            self.link = link; self.regime = regime; self.tieTolerance = tieTolerance
            self.unmeasuredMargin = max(tieTolerance, unmeasuredMargin); self.measuresPair = measuresPair
            self.aloneRoute = aloneRoute
        }

        /// The members a request may be routed to alone: under the alone
        /// route's opt-in, the last rank of a phase split (it loads every
        /// earlier range to decode alone). Otherwise none: under a pipeline or
        /// tensor parallel every member holds only its shard.
        public var membersHoldingWholeModel: [ClusterPlacementDevice] {
            guard aloneRoute, mode.isPhaseSplit, let last = devices.last else { return [] }
            return [last]
        }
    }

    /// The output length a route is priced at: the request's own limit, or
    /// the median of what this setup recently answered when that is shorter
    /// (clients ask for far more than they get).
    public static func expectedOutputTokens(maximum: Int, served: [ClusterServedSample]) -> Int {
        let recent = served.suffix(ClusterServedSpeedRecords.keptPerRoute).map { Double($0.outputTokens) }
        guard let typical = ClusterServedCalibration.median(recent) else { return max(1, maximum) }
        return max(1, min(maximum, Int(typical.rounded())))
    }

    /// Observed over predicted for the samples of one route nearest this
    /// prompt length: those within a factor of two when any, else the
    /// nearest one. Nil without samples.
    static func correction(_ samples: [ClusterServedSample], promptTokens: Int,
                           predict: (ClusterServedSample) throws -> ClusterPlacementPrediction) rethrows
        -> (firstToken: Double, decode: Double?)? {
        guard !samples.isEmpty else { return nil }
        func distance(_ s: ClusterServedSample) -> Double { abs(log(Double(s.promptTokens) / Double(max(1, promptTokens)))) }
        var near = samples.filter { distance($0) <= log(2.0) }
        if near.isEmpty, let nearest = samples.min(by: { distance($0) < distance($1) }) { near = [nearest] }
        var first: [Double] = [], decode: [Double] = []
        for s in near {
            let p = try predict(s)
            first.append(s.firstTokenSeconds / p.firstTokenSeconds)
            if let observed = s.decodeTokensPerSecond { decode.append(observed / p.decodeTokensPerSecond) }
        }
        guard let f = ClusterServedCalibration.median(first) else { return nil }
        return (f, ClusterServedCalibration.median(decode))
    }

    struct Priced { let seconds: Double; let firstToken: Double; let basis: ClusterRequestRoute.Basis }

    static func price(_ prediction: ClusterPlacementPrediction, outputs: Int,
                      correction: (firstToken: Double, decode: Double?)?, borrowed: Bool = false) -> Priced {
        let first = prediction.firstTokenSeconds * (correction?.firstToken ?? 1)
        let rate = prediction.decodeTokensPerSecond * (correction?.decode ?? 1)
        // The first token's own time includes a phase split's hand-off; the planner adds it to the request.
        let handoff = max(0, prediction.requestSeconds - prediction.firstTokenSeconds
            - Double(max(0, outputs - 1)) / prediction.decodeTokensPerSecond)
        return .init(seconds: first + handoff * (correction?.firstToken ?? 1) + Double(max(0, outputs - 1)) / rate,
                     firstToken: first, basis: correction == nil || borrowed ? .predicted : .served)
    }

    /// `measuring`: prompt lengths a serving router already sent to the pair
    /// to measure it, whose records have not arrived yet.
    public static func decide(_ setup: Setup, promptTokens: Int, outputTokens: Int,
                              served: [ClusterServedSample] = [], measuring: [Int] = []) throws -> ClusterRequestRoute {
        guard promptTokens >= 1, outputTokens >= 1 else { throw ClusterPlacementError("A routed request has a prompt and an output") }
        var policy = ClusterPlacementPolicy()
        policy.regime = setup.regime
        func pairPrediction(prompt: Int, outputs: Int) throws -> ClusterPlacementPrediction {
            policy.promptTokens = prompt; policy.outputTokens = outputs
            return try ClusterPlacementPlanner.evaluate(devices: setup.devices, cuts: setup.cuts, mode: setup.mode,
                prefillSchedule: setup.schedule, layout: setup.layout, policy: policy, link: setup.link).prediction(setup.regime)
        }
        let samples = served.filter(\.valid)
        let pairSamples = samples.filter { $0.route == .pair }
        let pairCorrection = try correction(pairSamples, promptTokens: promptTokens) {
            try pairPrediction(prompt: $0.promptTokens, outputs: $0.outputTokens)
        }
        // Each member holding the whole model, priced as it would serve alone.
        struct Alone { let device: ClusterPlacementDevice; let prediction: (Int, Int) -> ClusterPlacementPrediction
                       let correction: (firstToken: Double, decode: Double?)? }
        let alones = setup.membersHoldingWholeModel.map { device -> Alone in
            func alonePrediction(prompt: Int, outputs: Int) -> ClusterPlacementPrediction {
                var p = policy; p.promptTokens = prompt; p.outputTokens = outputs
                // It holds the head only when the placement's mode loads one on it.
                return ClusterPlacementPlanner.evaluateAlone(device: device, layout: setup.layout,
                    speculativeHead: setup.mode.usesSpeculativeHead, policy: p)
            }
            let own = samples.filter { $0.route == .alone && $0.member == device.label }
            return .init(device: device, prediction: alonePrediction,
                correction: correction(own, promptTokens: promptTokens) { alonePrediction(prompt: $0.promptTokens, outputs: $0.outputTokens) })
        }
        // Without a measured speed for every member, predictions are in the
        // speed index's relative units and only a served route is in seconds:
        // a route without samples then takes the served route's scale, so the
        // two are compared in the same units (the ratio stays the planner's).
        let relative = !setup.devices.allSatisfy(\.speed.absolute)
        let shared = pairCorrection ?? alones.compactMap(\.correction).first
        let pair = price(try pairPrediction(prompt: promptTokens, outputs: outputTokens), outputs: outputTokens,
            correction: pairCorrection ?? (relative ? shared : nil), borrowed: pairCorrection == nil)
        var best: (device: ClusterPlacementDevice, priced: Priced)?
        for alone in alones {
            let priced = price(alone.prediction(promptTokens, outputTokens), outputs: outputTokens,
                correction: alone.correction ?? (relative ? shared : nil), borrowed: alone.correction == nil)
            if best == nil || priced.seconds < best!.priced.seconds { best = (alone.device, priced) }
        }
        func make(_ path: ClusterServedSample.Route, _ reason: String) -> ClusterRequestRoute {
            .init(path: path, member: path == .alone ? best?.device.label : nil, aloneCandidate: best?.device.label,
                  promptTokens: promptTokens, outputTokens: outputTokens, pairSeconds: pair.seconds,
                  pairFirstTokenSeconds: pair.firstToken, pairBasis: pair.basis, aloneSeconds: best?.priced.seconds,
                  aloneFirstTokenSeconds: best?.priced.firstToken, aloneBasis: best?.priced.basis, reason: reason)
        }
        guard let best else {
            return make(.pair, !setup.aloneRoute
                ? "the alone route is off by default (sharded deployments only): every request uses the cluster as placed"
                : setup.mode.isPhaseSplit
                ? "no member holds the whole model"
                : "no member holds the whole model under \(setup.mode.rawValue): every request uses the pair")
        }
        let gain = best.priced.seconds / pair.seconds - 1
        // Both routes measured near this length: the tie tolerance decides. Otherwise the larger margin.
        func near(_ s: ClusterServedSample) -> Bool { abs(log(Double(s.promptTokens) / Double(promptTokens))) <= log(2.0) }
        let pairNear = samples.contains { $0.route == .pair && near($0) }
        let aloneNear = samples.contains { $0.route == .alone && $0.member == best.device.label && near($0) }
        let measured = pairNear && aloneNear
        if gain > (measured ? setup.tieTolerance : setup.unmeasuredMargin) {
            return make(.pair, String(format: "the pair is predicted %.0f%% faster than %@ alone", gain * 100, best.device.label)
                + (measured ? ", both measured near this length" : ""))
        }
        let beingMeasured = measuring.contains { abs(log(Double($0) / Double(promptTokens))) <= log(2.0) }
        if gain > setup.tieTolerance, setup.measuresPair, aloneNear, !pairNear, !beingMeasured {
            var value = make(.pair, String(format: "measuring the pair once near this length: %@ alone was measured here and the pair "
                + "is still predicted %.0f%% faster", best.device.label, gain * 100))
            value.measuring = true
            return value
        }
        if gain > setup.tieTolerance {
            return make(.alone, String(format: "the pair is predicted %.0f%% faster, but the two were not both measured near this length; "
                + "%@ alone serves it (the pair must never make a request slower) until they are", gain * 100, best.device.label))
        }
        return make(.alone, gain >= 0
            ? String(format: "%@ alone is predicted within %.0f%% of the pair, so the pair would not make it faster", best.device.label, setup.tieTolerance * 100)
            : String(format: "%@ alone is predicted %.0f%% faster than the pair", best.device.label, -gain / (1 + gain) * 100))
    }

    /// The shortest prompt the pair is chosen for at this output length, by
    /// the same decision; nil when it is never chosen up to `maximumPrompt`
    /// (or no member holds the whole model, when it is always chosen: 1).
    public static func crossoverPromptTokens(_ setup: Setup, outputTokens: Int, maximumPrompt: Int,
                                             served: [ClusterServedSample] = []) throws -> Int? {
        func pairWins(_ prompt: Int) throws -> Bool {
            try decide(setup, promptTokens: prompt, outputTokens: outputTokens, served: served).path == .pair
        }
        guard maximumPrompt >= 1 else { return nil }
        if try pairWins(1) { return 1 }
        // Doubling to the first prompt the pair wins at, then bisection below it.
        var low = 1, high = 1
        repeat {
            low = high; high = min(maximumPrompt, high * 2)
            if try pairWins(high) { break }
            if high == maximumPrompt { return nil }
        } while true
        while high - low > 1 {
            let middle = (low + high) / 2
            if try pairWins(middle) { high = middle } else { low = middle }
        }
        return high
    }
}

/// The router a serving leader keeps for one formed setup: one decision per
/// request, from the setup's placement and the speed records it has served
/// (re-read through `served` at most every `refreshSeconds`). Thread-safe.
/// Any failure to decide routes the request to the pair as placed, which is
/// always a qualified path.
public final class ClusterRequestRouting: @unchecked Sendable {
    public let setup: ClusterRequestRouter.Setup
    private let served: @Sendable () -> [ClusterServedSample]
    private let refreshSeconds: Double
    private let clock: @Sendable () -> Double
    private let lock = NSLock()
    private var samples: [ClusterServedSample] = []
    private var readAt = -Double.infinity
    /// Prompt lengths sent to the pair to measure it, and those sent since the last refresh (whose records may
    /// not have arrived). A session's first request on a route is not a speed record (it warms that path), so a
    /// band is measured at most twice, at most once per refresh.
    private var measuredAttempts: [Int] = []
    private var measuringNow: [Int] = []
    public static let measuringAttemptsPerBand = 2

    public init(setup: ClusterRequestRouter.Setup, refreshSeconds: Double = 30,
                clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
                served: @escaping @Sendable () -> [ClusterServedSample]) {
        self.setup = setup; self.served = served; self.refreshSeconds = refreshSeconds; self.clock = clock
    }

    public func route(promptTokens: Int, maximumOutputTokens: Int) -> ClusterRequestRoute? {
        let now = clock()
        return lock.withLock {
            if now - readAt >= refreshSeconds { samples = served(); readAt = now; measuringNow = [] }
            let outputs = ClusterRequestRouter.expectedOutputTokens(maximum: maximumOutputTokens, served: samples)
            func band(_ a: Int, _ b: Int) -> Bool { abs(log(Double(a) / Double(b))) <= log(2.0) }
            let exhausted = measuredAttempts.filter { length in
                measuredAttempts.filter { band($0, length) }.count >= Self.measuringAttemptsPerBand
            }
            let decided = try? ClusterRequestRouter.decide(setup, promptTokens: promptTokens, outputTokens: outputs,
                served: samples, measuring: measuringNow + exhausted)
            if let decided, decided.measuring { measuredAttempts.append(promptTokens); measuringNow.append(promptTokens) }
            return decided
        }
    }
}

extension ClusterServedSample {
    /// A served sample from what a leader's telemetry record carries (route
    /// `pair` or `alone:<member>`); nil when the record is no speed record:
    /// failed, restored from a prefix cache, or without a first token.
    public static func fromTelemetry(route: String?, promptTokens: Int, cachedTokens: Int, completionTokens: Int,
                                     firstTokenMilliseconds: Double?, decodeTokensPerSecond: Double?, outcome: String,
                                     finishedAt: Double) -> ClusterServedSample? {
        guard cachedTokens == 0, outcome == "stop" || outcome == "length", let first = firstTokenMilliseconds else { return nil }
        let label = route ?? "pair"
        let member = label.hasPrefix("alone:") ? String(label.dropFirst(6)) : nil
        guard member != nil || label == "pair" else { return nil }
        let value = ClusterServedSample(route: member == nil ? .pair : .alone, member: member, promptTokens: promptTokens,
            outputTokens: completionTokens, firstTokenSeconds: first / 1_000, decodeTokensPerSecond: decodeTokensPerSecond,
            finishedAt: finishedAt)
        return value.valid ? value : nil
    }
}
