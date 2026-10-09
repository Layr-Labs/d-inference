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
public enum ClusterGenerationMode: String, Codable, CaseIterable, Sendable {
    case pipeline = "pipeline_v1"
    case pipelineCompactDecode = "pipeline_compact_decode_v1"
    case phaseSplit = "phase_split_v1"
}
