import Foundation

/// How the two ranks divide one request. Declared to both ranks when they are
/// launched; never inferred from a request. Support must be advertised by the
/// installed adapter for the registered model and is admitted natively: both
/// ranks bind the mode into their load agreement before either stage is read.
///
/// `pipeline`: every frame passes through rank 0 and then rank 1.
/// `pipelineCompactDecode`: the same pipeline; each decode step's messages
/// travel as four transfers instead of eleven.
/// `phaseSplit`: the prompt is prefilled as a pipeline; after the first
/// selected token rank 0 hands its request state to rank 1, which holds every
/// layer and decodes alone.
/// `phaseSplitMTP`: the same phase split; rank 1 also holds the model's
/// speculative (multi-token prediction) head and decodes with the product's
/// drafter and verifier. Only a model whose artifact ships a head lists it.
/// `pipelineMTP`: the pipeline, with decode as speculative rounds: the last
/// rank also holds the model's head (and a copy of its token embedding),
/// drafts, and both ranks verify the window of drafts in one forward each.
/// Only a model whose artifact ships a head the last rank can run lists it.
public enum ClusterGenerationMode: String, Codable, CaseIterable, Sendable {
    case pipeline = "pipeline_v1"
    case pipelineCompactDecode = "pipeline_compact_decode_v1"
    case phaseSplit = "phase_split_v1"
    case phaseSplitMTP = "phase_split_mtp_v1"
    case pipelineMTP = "pipeline_mtp_v1"

    /// Rank 0 hands its request state to rank 1 after the prompt, and rank 1
    /// holds every layer.
    public var isPhaseSplit: Bool { self == .phaseSplit || self == .phaseSplitMTP }
    /// The last rank drafts with the model's speculative head and the window
    /// is verified by the target.
    public var usesSpeculativeHead: Bool { self == .phaseSplitMTP || self == .pipelineMTP }
}
