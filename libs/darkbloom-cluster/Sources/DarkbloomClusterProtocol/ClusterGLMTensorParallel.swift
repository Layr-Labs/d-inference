import Foundation

/// What GLM-5.3-Flash's tensor-parallel runtime binds into every load, for a
/// provider that describes a placed pair from its saved setup without loading
/// it. The runtime (`GLM5NextTensorParallelResidentRuntime.mtpDepth`) decodes
/// with the artifact's own NextN (MTP) head at this depth on every load of
/// `tensor_parallel_v1`; no generation mode names that head, so a status read
/// from the setup alone would report the placement as decoding one token per
/// step.
public enum ClusterGLMTensorParallel {
    /// NextN proposals each greedy decode round verifies; 0 would load no NextN
    /// layer.
    public static let speculativeDepth = 2

    /// Whether a placement of `runtimeModelID` in `mode` decodes with the NextN
    /// head: tensor parallel of the registered GLM row. Its pipeline runs no
    /// head.
    public static func decodesWithHead(runtimeModelID: String, mode: ClusterGenerationMode) -> Bool {
        runtimeModelID == ClusterGLMImageCandidate.runtimeModelID && mode == .tensorParallel && speculativeDepth > 0
    }
}
