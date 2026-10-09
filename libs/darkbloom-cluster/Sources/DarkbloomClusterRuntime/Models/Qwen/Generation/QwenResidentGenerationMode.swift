import Foundation

/// How the two ranks divide one request. Declared when both ranks load and
/// bound into their load agreement, so a rank that was told something else
/// stops before either stage is read. Never inferred from a request.
///
/// `pipeline`: every frame passes through rank 0 and then rank 1.
/// `pipelineCompactDecode`: the same pipeline; each decode step's messages
/// travel as four transfers instead of eleven (see the generation transport).
/// `phaseSplit`: the prompt is prefilled as a pipeline; after the first
/// selected token rank 0 hands its request state to rank 1, which holds every
/// layer and decodes alone.
public enum QwenResidentGenerationMode: String, Sendable, CaseIterable {
    case pipeline = "pipeline_v1"
    case pipelineCompactDecode = "pipeline_compact_decode_v1"
    case phaseSplit = "phase_split_v1"

    /// The worker's launcher declares the mode with this name until the worker
    /// carries a flag for it. Absence means the pipeline.
    public static let environmentName = "DARKBLOOM_CLUSTER_GENERATION_MODE"

    /// The caller passes the actual process environment. Present-but-unknown
    /// is refused: a misspelt declaration must not silently run the default.
    public static func admit(environment: [String: String]) throws -> Self {
        guard let value = environment[environmentName] else { return .pipeline }
        guard let mode = Self(rawValue: value) else {
            throw ProbeError("Unknown \(environmentName); expected "
                + allCases.map(\.rawValue).joined(separator: " or "))
        }
        return mode
    }

    /// Extra load-agreement fields. The pipeline's agreement bytes are unchanged.
    var loadAgreementFields: [String] {
        self == .pipeline ? [] : ["qwen-resident-generation-mode-v1", rawValue]
    }
}
