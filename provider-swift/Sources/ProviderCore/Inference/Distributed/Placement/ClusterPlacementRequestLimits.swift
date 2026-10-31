import Foundation
import DarkbloomClusterPlacement
import DarkbloomClusterProtocol

/// A setup's request limits, derived instead of typed (owner, "universal
/// mechanisms"): the prefill chunk from the model's qualification records and
/// its own limits, and the request deadline from the chosen placement's
/// predicted speed on the detected hardware for the longest request the model
/// admits. No value here is tuned for one model or one pair of chips.
public enum ClusterPlacementRequestLimits {
    /// Margins that turn a prediction into a deadline. Policy, typed on
    /// purpose, beside the prediction it scales.
    public struct Policy: Sendable {
        /// A request may take this many times its predicted time.
        public var margin = 3.0
        /// Added once: scheduling, the first frames and a slow start.
        public var baseSeconds = 30.0
        /// The bounds the setup codec admits, and a floor below which a
        /// prediction is not trusted to end a request.
        public var floorSeconds = 60
        public var ceilingSeconds = 3600
        public init() {}
    }

    /// A chunk preference from passing records whose prompts were at least
    /// their configured chunk (most common, larger on a tie). A short prompt
    /// does not exercise its chunk cap. Artifact identity narrows the hint when
    /// supplied; nil preserves model-only callers. Neither this preference nor
    /// the largest-admitted fallback grants traffic or qualifies speed/current
    /// binaries. Actual exercised frame geometry is not recorded here.
    public static func chunkTokens(runtimeModelID: String, artifactSHA256: String? = nil,
                                   layoutMaximum: Int, capabilityMaximum: Int,
                                   records: [ClusterPairQualificationRecord] = ClusterPairServingGrants.records) -> (tokens: Int, basis: String) {
        let limit = max(1, min(layoutMaximum, capabilityMaximum))
        let artifact = artifactSHA256.map {
            ClusterPairServingGrants.qualifyingArtifact(for: $0, runtimeModelID: runtimeModelID)
        }
        let runs = records.filter {
            $0.runtimeModelID == runtimeModelID
                && (artifact == nil || $0.artifactSHA256 == artifact)
                && $0.isConsistent && $0.outcome == .passed
                && $0.chunkTokens <= limit && $0.promptTokens >= $0.chunkTokens
        }
        let counts = Dictionary(grouping: runs, by: \.chunkTokens).mapValues(\.count)
        if let chosen = counts.max(by: { ($0.value, $0.key) < ($1.value, $1.key) }) {
            return (chosen.key, "\(chosen.key) prompt tokens a frame: preferred by \(chosen.value) passing run\(chosen.value == 1 ? "" : "s") with prompts at least that long")
        }
        return (limit, "\(limit) prompt tokens a frame: largest supported chunk; no matching long-prompt measurement is available")
    }

    /// The request deadline: the chosen placement's predicted time for the
    /// longest request the model admits (its longest prompt, then its most
    /// output tokens), times the margin, plus the base; within the codec's
    /// bounds. A placement planned from relative speeds only has no seconds to
    /// scale, so it gets the ceiling: an unmeasured guess never ends a request
    /// early, and the progress guard still ends a stalled one.
    public static func requestTimeoutSeconds(result: ClusterPlacementResult, chosen: ClusterPlacementCandidate,
                                             maximumPromptTokens: Int, maximumOutputTokens: Int,
                                             policy: Policy = .init()) -> (seconds: Int, basis: String) {
        let prediction = chosen.prediction(result.regime)
        guard result.basis.absolute, result.promptTokens > 0, prediction.firstTokenSeconds.isFinite, prediction.firstTokenSeconds > 0,
              prediction.decodeTokensPerSecond.isFinite, prediction.decodeTokensPerSecond > 0 else {
            return (policy.ceilingSeconds, "\(policy.ceilingSeconds) s: the plan's speeds are relative only, so no measured time bounds a request")
        }
        let prefill = prediction.firstTokenSeconds / Double(result.promptTokens) * Double(max(0, maximumPromptTokens))
        let decode = Double(max(0, maximumOutputTokens)) / prediction.decodeTokensPerSecond
        let scaled = (policy.margin * (prefill + decode) + policy.baseSeconds).rounded(.up)
        let seconds = min(policy.ceilingSeconds, max(policy.floorSeconds, Int(scaled.isFinite ? scaled : Double(policy.ceilingSeconds))))
        return (seconds, String(format: "%d s: the longest request (%d prompt tokens, %d output tokens) is predicted at %.0f s on this placement, times %.1f, plus %.0f s",
                                seconds, maximumPromptTokens, maximumOutputTokens, prefill + decode, policy.margin, policy.baseSeconds))
    }
}
