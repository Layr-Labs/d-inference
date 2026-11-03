import Foundation

/// What one generation mode keeps of a model's serving features as this worker
/// build runs it, declared by the adapter beside its modes
/// (`ClusterRuntimeCapability.modeFeatures`) from the facts its loads bind (a
/// load agreement without a prompt-prefix cache, a lane count it refuses above
/// one). The placement step compares modes by these and keeps no table of its
/// own: a mode is chosen only where it keeps every feature of the mode it would
/// replace (`dropped(by:)`; owner, 2026-11-01).
public struct ClusterServingFeatures: Equatable, Sendable {
    public enum Media: String, CaseIterable, Sendable { case images, video }

    /// Resident prompt-prefix reuse: a prompt that starts with one served
    /// before restores that prefix's state instead of prefilling it again.
    public let promptPrefixReuse: Bool
    /// The owner's SSD tier of that cache.
    public let ssdPrefixTier: Bool
    /// Decode in speculative rounds: the model's own head drafts and the
    /// target verifies the window, keeping only its greedy tokens.
    public let speculativeRounds: Bool
    /// The widest batch-lane width a load of the mode accepts; 1 serves one
    /// request at a time.
    public let maximumLanes: Int
    /// Media a request may carry beside text, in `Media` order.
    public let requestMedia: [Media]
    /// Repetition, presence and frequency penalties and logit bias, applied by
    /// the product's sampler.
    public let penaltiesAndLogitBias: Bool
    /// Stop token IDs and stop strings.
    public let stopHandling: Bool
    /// Committed-token logprobs.
    public let logprobs: Bool

    public static let maximumLaneWidth = 8

    public init(promptPrefixReuse: Bool, ssdPrefixTier: Bool, speculativeRounds: Bool, maximumLanes: Int,
                requestMedia: [Media] = [], penaltiesAndLogitBias: Bool = true, stopHandling: Bool = true, logprobs: Bool) {
        self.promptPrefixReuse = promptPrefixReuse; self.ssdPrefixTier = ssdPrefixTier
        self.speculativeRounds = speculativeRounds; self.maximumLanes = maximumLanes; self.requestMedia = requestMedia
        self.penaltiesAndLogitBias = penaltiesAndLogitBias; self.stopHandling = stopHandling; self.logprobs = logprobs
    }

    /// What `other` would drop of these features, in plain words and this
    /// order; empty when it keeps every one. What `other` has beyond them
    /// (logprobs these lack, wider lanes) is a gain and never counts.
    public func dropped(by other: ClusterServingFeatures) -> [String] {
        var dropped: [String] = []
        if promptPrefixReuse && !other.promptPrefixReuse { dropped.append("prompt-prefix reuse") }
        if ssdPrefixTier && !other.ssdPrefixTier { dropped.append("the SSD prefix tier") }
        if speculativeRounds && !other.speculativeRounds { dropped.append("speculative (MTP) rounds") }
        if other.maximumLanes < maximumLanes { dropped.append("batch lanes up to \(maximumLanes) (it serves \(other.maximumLanes))") }
        dropped += requestMedia.filter { !other.requestMedia.contains($0) }.map(\.rawValue)
        if penaltiesAndLogitBias && !other.penaltiesAndLogitBias { dropped.append("penalties and logit bias") }
        if stopHandling && !other.stopHandling { dropped.append("stop handling") }
        if logprobs && !other.logprobs { dropped.append("committed-token logprobs") }
        return dropped
    }

    func validate() throws {
        try workerRequire((1...Self.maximumLaneWidth).contains(maximumLanes)
            && requestMedia == Media.allCases.filter(requestMedia.contains) && (promptPrefixReuse || !ssdPrefixTier),
            "Malformed serving features")
    }

    var wireObject: [String: Any] {
        ["promptPrefixReuse": promptPrefixReuse, "ssdPrefixTier": ssdPrefixTier, "speculativeRounds": speculativeRounds,
         "maximumLanes": maximumLanes, "requestMedia": requestMedia.map(\.rawValue), "penaltiesAndLogitBias": penaltiesAndLogitBias,
         "stopHandling": stopHandling, "logprobs": logprobs]
    }

    static func decode(wire object: [String: Any]) throws -> Self {
        var r = WorkerObject(object)
        guard let names = try r.take("requestMedia") as? [String] else {
            throw ClusterWorkerProtocolError.invalid("Expected media names")
        }
        let requestMedia = try names.map {
            guard let kind = Media(rawValue: $0) else { throw ClusterWorkerProtocolError.invalid("Unknown media kind") }
            return kind
        }
        let value = try Self(promptPrefixReuse: r.bool("promptPrefixReuse"), ssdPrefixTier: r.bool("ssdPrefixTier"),
            speculativeRounds: r.bool("speculativeRounds"), maximumLanes: r.int("maximumLanes"), requestMedia: requestMedia,
            penaltiesAndLogitBias: r.bool("penaltiesAndLogitBias"), stopHandling: r.bool("stopHandling"),
            logprobs: r.bool("logprobs"))
        try r.finish()
        try value.validate()
        return value
    }
}
