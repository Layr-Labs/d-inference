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
        public init(devices: [ClusterPlacementDevice], cuts: [Int], mode: ClusterGenerationMode, schedule: ClusterPrefillSchedule,
                    layout: ClusterModelLayout, link: ClusterLinkCosts = .unmeasured,
                    regime: ClusterPlacementPolicy.Regime = .rested, tieTolerance: Double = 0.03) {
            self.devices = devices; self.cuts = cuts; self.mode = mode; self.schedule = schedule; self.layout = layout
            self.link = link; self.regime = regime; self.tieTolerance = tieTolerance
        }

        /// The members holding every layer under this placement: the last
        /// rank of a phase split (it loads every earlier range to decode
        /// alone). Under a pipeline every member holds only its range.
        public var membersHoldingWholeModel: [ClusterPlacementDevice] {
            guard mode.isPhaseSplit, let last = devices.last else { return [] }
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
                      correction: (firstToken: Double, decode: Double?)?) -> Priced {
        let first = prediction.firstTokenSeconds * (correction?.firstToken ?? 1)
        let rate = prediction.decodeTokensPerSecond * (correction?.decode ?? 1)
        // The first token's own time includes a phase split's hand-off; the planner adds it to the request.
        let handoff = max(0, prediction.requestSeconds - prediction.firstTokenSeconds
            - Double(max(0, outputs - 1)) / prediction.decodeTokensPerSecond)
        return .init(seconds: first + handoff * (correction?.firstToken ?? 1) + Double(max(0, outputs - 1)) / rate,
                     firstToken: first, basis: correction == nil ? .predicted : .served)
    }

    public static func decide(_ setup: Setup, promptTokens: Int, outputTokens: Int,
                              served: [ClusterServedSample] = []) throws -> ClusterRequestRoute {
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
        let pair = price(try pairPrediction(prompt: promptTokens, outputs: outputTokens), outputs: outputTokens,
            correction: try correction(pairSamples, promptTokens: promptTokens) {
                try pairPrediction(prompt: $0.promptTokens, outputs: $0.outputTokens)
            })
        // The fastest member holding the whole model, priced as it would serve alone.
        var best: (device: ClusterPlacementDevice, priced: Priced)?
        for device in setup.membersHoldingWholeModel {
            func alonePrediction(prompt: Int, outputs: Int) -> ClusterPlacementPrediction {
                policy.promptTokens = prompt; policy.outputTokens = outputs
                // It holds the head only when the placement's mode loads one on it.
                return ClusterPlacementPlanner.evaluateAlone(device: device, layout: setup.layout,
                    speculativeHead: setup.mode.usesSpeculativeHead, policy: policy)
            }
            let own = samples.filter { $0.route == .alone && $0.member == device.label }
            let priced = price(alonePrediction(prompt: promptTokens, outputs: outputTokens), outputs: outputTokens,
                correction: correction(own, promptTokens: promptTokens) { alonePrediction(prompt: $0.promptTokens, outputs: $0.outputTokens) })
            if best == nil || priced.seconds < best!.priced.seconds { best = (device, priced) }
        }
        func make(_ path: ClusterServedSample.Route, _ reason: String) -> ClusterRequestRoute {
            .init(path: path, member: path == .alone ? best?.device.label : nil, aloneCandidate: best?.device.label,
                  promptTokens: promptTokens, outputTokens: outputTokens, pairSeconds: pair.seconds,
                  pairFirstTokenSeconds: pair.firstToken, pairBasis: pair.basis, aloneSeconds: best?.priced.seconds,
                  aloneFirstTokenSeconds: best?.priced.firstToken, aloneBasis: best?.priced.basis, reason: reason)
        }
        guard let best else {
            return make(.pair, setup.mode.isPhaseSplit
                ? "no member holds the whole model"
                : "no member holds the whole model under \(setup.mode.rawValue): every request uses the pair")
        }
        let gain = best.priced.seconds / pair.seconds - 1
        if gain > setup.tieTolerance {
            return make(.pair, String(format: "the pair is predicted %.0f%% faster than %@ alone", gain * 100, best.device.label))
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
