import Foundation
import MLXLMCommon

extension EngineV2Bridge {
    /// The slot serves through a cluster pair (`DistributedCBv2Engine`): the
    /// pair-only request behavior keys on this, never on the request.
    var servesDistributedPair: Bool { ownedEngine is DistributedCBv2Engine }

    /// What a request to this pair slot may carry: images and video on the
    /// tensor-parallel GLM and Qwen pairs whose ranks serve their media
    /// contracts (`ClusterGLMMedia`, `ClusterQwenMedia`), images on the GLM
    /// image profile, and text alone otherwise (every pipeline, and the Gemma
    /// and MiMo pairs).
    nonisolated var pairInputModalities: [String] {
        ["text"]
    }
}
