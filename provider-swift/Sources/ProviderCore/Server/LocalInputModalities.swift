import Foundation

/// `input_modalities` in this Mac's `/v1/models`: what a request may carry, as this Mac's engine serves a model. The
/// one place the provider turns what an engine takes into these names (one Mac, a pair's slot), and where the
/// integrations read them back. Reasoning isn't among them: the engine doesn't say which models reason, so that stays
/// the catalog's.
public enum LocalInputModalities {
    /// `text`, then `image` for an engine that takes images, and `video` for one that takes video as well.
    static func list(image: Bool, video: Bool) -> [String] {
        ["text"] + (image ? ["image"] : []) + (image && video ? ["video"] : [])
    }

    /// One Mac, for a model it serves, loaded or not: images when the model advertises vision (`ModelInfo.isVision`,
    /// which the coordinator routes images on).
    static func of(_ model: ModelInfo) -> [String] {
        list(image: model.isVision == true, video: false)
    }

    /// A pair's slot: images and video on the tensor-parallel GLM and Qwen pairs whose ranks serve their media
    /// contracts (`ClusterGLMMedia`, `ClusterQwenMedia`), images on the GLM image profile, and text alone otherwise
    /// (every pipeline, and the Gemma and MiMo pairs), whatever the model takes on one Mac.
    static func of(pair slot: EngineV2Bridge) -> [String] {
        let media = slot.clusterGLMMediaIngress != nil || slot.clusterQwenMediaIngress != nil
        return list(image: media || slot.clusterGLMImageConfiguration != nil, video: media)
    }

    /// A model whose list entry says `modalities` takes images (`image`, in any case).
    public static func takesImages(_ modalities: [String]?) -> Bool {
        modalities?.contains { $0.lowercased() == "image" } == true
    }
}
