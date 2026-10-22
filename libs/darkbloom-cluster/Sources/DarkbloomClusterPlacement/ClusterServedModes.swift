import DarkbloomClusterProtocol
import Foundation

/// What a pair served in each sharded mode, compared directly for one request,
/// and the mode a plan of that pair keeps because of it (`ClusterPlacementPolicy.keptMode`).
///
/// The planner's figures are predictions from per-device rates; a pair that
/// has served both modes measured both on itself. On the M5 Ultra pair
/// (2026-10-22) the planner predicted 34.6 tok/s for tensor parallel and
/// 19.1 for a pipeline while the pair served 88 and 48: a choice between the
/// two modes is better made from what was served once both were.
///
/// A served request is only as fast as the pair let it be: one that shared
/// the pair with others (time-sliced lanes) decoded at a fraction of the
/// pair's speed. So a mode's figure is read at the fast end of its samples
/// (`fastShare`), never their median: contention only slows a request down.
public enum ClusterServedModes {
    /// A setup's served figure counts from this many pair requests on.
    public static let minimumSamples = 3
    /// One mode is "served faster" only by at least this share of request time; also the margin by which the
    /// planner must predict another mode faster before a plan after an update leaves the mode the pair served.
    public static let margin = 0.10
    /// The rank, from the slowest, at which a setup's decode rate and first-token time are read (0.9: the
    /// tenth-fastest of a hundred requests), so requests that shared the pair do not set the figure.
    public static let fastShare = 0.9

    /// One mode's figure: its fastest served setup, at the reference request.
    public struct Figure: Equatable, Sendable {
        public let mode: ClusterGenerationMode
        /// The setup's cut string (`ClusterServedSpeedRecords.Setup.cut`).
        public let cut: String
        public let samples: Int
        public let firstTokenSeconds: Double
        public let decodeTokensPerSecond: Double
        /// The first token plus `outputTokens - 1` decode steps.
        public let requestSeconds: Double
    }

    /// The value at `share` of `values` sorted ascending (nearest rank); nil when empty.
    static func quantile(_ values: [Double], _ share: Double) -> Double? {
        let sorted = values.filter { $0.isFinite && $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return nil }
        let index = Int((Double(sorted.count - 1) * min(1, max(0, share))).rounded())
        return sorted[index]
    }

    /// Each served mode's figure for a request of `promptTokens` and `outputTokens`, fastest mode first: per
    /// setup (mode and cut) with at least `minimumSamples` pair requests that decoded, the decode rate at
    /// `fastShare` and the first token of the samples nearest the reference prompt (scaled to it) at
    /// `1 - fastShare`; a mode's figure is its fastest setup. Rough for the first token, which is why the
    /// comparison needs a `margin`; what decides a decode-heavy request is the decode rate. `entries` are one
    /// model's on one pair (the caller filters them, as the planner does).
    public static func figures(_ entries: [ClusterServedSpeedRecords.Entry], promptTokens: Int,
                               outputTokens: Int) -> [Figure] {
        guard promptTokens >= 1, outputTokens >= 1 else { return [] }
        var setups: [ClusterServedSpeedRecords.Setup] = []
        for entry in entries where !setups.contains(entry.setup) { setups.append(entry.setup) }
        var best: [ClusterGenerationMode: Figure] = [:]
        for setup in setups {
            guard let mode = ClusterGenerationMode(rawValue: setup.mode) else { continue }
            let samples = entries.filter { $0.setup == setup }.map(\.sample).filter { $0.valid && $0.route == .pair }
            let decodes = samples.compactMap(\.decodeTokensPerSecond)
            guard samples.count >= minimumSamples, decodes.count >= minimumSamples,
                  let decode = quantile(decodes, fastShare) else { continue }
            // The samples whose prompt is within twice or half the reference (else the `minimumSamples` nearest), each
            // first token scaled to the reference prompt: a first token grows with its prompt, and scaling from a far
            // longer prompt would drop the fixed part of a short one.
            func distance(_ s: ClusterServedSample) -> Double { abs(log(Double(s.promptTokens) / Double(promptTokens))) }
            let sorted = samples.sorted { distance($0) < distance($1) }
            let within = sorted.filter { distance($0) <= log(2) }
            let near = within.count >= minimumSamples ? within : Array(sorted.prefix(minimumSamples))
            guard let first = quantile(near.map { $0.firstTokenSeconds * Double(promptTokens) / Double($0.promptTokens) },
                                       1 - fastShare) else { continue }
            let figure = Figure(mode: mode, cut: setup.cut, samples: samples.count, firstTokenSeconds: first,
                decodeTokensPerSecond: decode, requestSeconds: first + Double(outputTokens - 1) / decode)
            if let current = best[mode], current.requestSeconds <= figure.requestSeconds { continue }
            best[mode] = figure
        }
        return best.values.sorted { $0.requestSeconds != $1.requestSeconds ? $0.requestSeconds < $1.requestSeconds : $0.mode.rawValue < $1.mode.rawValue }
    }

    /// The mode the pair served faster than every other served mode by at least `margin`; nil with fewer than
    /// two served modes or a closer race.
    public static func servedFaster(_ figures: [Figure]) -> (faster: Figure, next: Figure)? {
        let sorted = figures.sorted { $0.requestSeconds < $1.requestSeconds }
        guard sorted.count >= 2, sorted[1].requestSeconds >= sorted[0].requestSeconds * (1 + margin) else { return nil }
        return (sorted[0], sorted[1])
    }

    /// The mode a plan keeps (`ClusterPlacementPolicy.keptMode`), how far another mode must be predicted faster
    /// to go ahead of it (`keptModeMargin`), and the reason the plan states when the hold decides.
    public struct Hold: Equatable, Sendable {
        public let mode: ClusterGenerationMode
        public let margin: Double
        public let reason: String
    }

    /// What a plan keeps, from what the pair served (`figures`, for the plan's reference request) and, when the
    /// same model is planned again after a Darkbloom update, the mode it served in (`incumbent`):
    ///
    /// - After an update the pair keeps its mode. Another mode goes ahead only when the planner predicts it at
    ///   least `margin` faster and the pair's own served requests agree (another mode served faster by `margin`);
    ///   without that agreement (a mode never served, or served slower) the mode is kept whenever it loads.
    /// - Otherwise, once the pair has served two modes and one served faster by `margin`, that mode is kept
    ///   whenever it loads: what the pair served outranks the planner's prediction.
    ///
    /// Only modes in `plannable` (what this worker and policy can place) are kept or compared. Memory still comes
    /// first: a kept mode that does not load now is overtaken by a placement that does.
    public static func hold(incumbent: ClusterGenerationMode?, figures: [Figure], plannable: [ClusterGenerationMode],
                            promptTokens: Int, outputTokens: Int) -> Hold? {
        let usable = figures.filter { plannable.contains($0.mode) }
        let race = servedFaster(usable)
        let request = "requests of \(promptTokens) prompt and \(outputTokens) answer tokens"
        func served(_ race: (faster: Figure, next: Figure)) -> String {
            String(format: "this pair served %@ %d%% faster than %@ for %@ (decode %.1f vs %.1f tok/s, first token %.2f s vs %.2f s served)",
                words(race.faster.mode), Int(((race.next.requestSeconds / race.faster.requestSeconds - 1) * 100).rounded()),
                words(race.next.mode), request, race.faster.decodeTokensPerSecond, race.next.decodeTokensPerSecond,
                race.faster.firstTokenSeconds, race.next.firstTokenSeconds)
        }
        if let incumbent {
            guard plannable.contains(incumbent) else { return nil }
            if let race, race.faster.mode != incumbent {
                return .init(mode: incumbent, margin: margin, reason: "kept after the update, as the pair served it: another mode is predicted "
                    + "less than \(Int(margin * 100))% faster, though \(served(race))")
            }
            let why = race.map(served) ?? (usable.contains { $0.mode != incumbent }
                ? "the modes this pair served are within \(Int(margin * 100))% of each other"
                : "this pair has not served another mode to compare it with")
            return .init(mode: incumbent, margin: .infinity,
                reason: "kept after the update, as the pair served it: a mode changes after an update only when the planner and "
                    + "this pair's own served requests both find another faster, and " + why)
        }
        guard let race else { return nil }
        return .init(mode: race.faster.mode, margin: .infinity, reason: served(race) + "; chosen over the planner's prediction")
    }

    /// The mode in plain words.
    public static func words(_ mode: ClusterGenerationMode) -> String {
        if mode.usesTensorParallelDecode { return mode == .tensorParallel ? "tensor parallel" : mode.rawValue }
        return mode == .pipeline ? "a pipeline" : mode.rawValue
    }

    /// One line per served mode, for the plan's explanation.
    public static func lines(_ figures: [Figure], promptTokens: Int, outputTokens: Int) -> [String] {
        figures.map { f in
            String(format: "  %@ (cut %@, %d request(s)): first token %.2f s, decode %.1f tok/s, %.2f s for %d prompt and %d answer tokens",
                f.mode.rawValue, f.cut, f.samples, f.firstTokenSeconds, f.decodeTokensPerSecond, f.requestSeconds, promptTokens, outputTokens)
        }
    }
}
