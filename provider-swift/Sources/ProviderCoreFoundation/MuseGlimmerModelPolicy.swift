// Copyright © 2026 Eigen Labs.

import Foundation

/// The one home of Muse Glimmer 30B's identity. Every policy list that names
/// the model (scan label, paged KV, SSD prefix default, sampling, MTP, tool
/// choice) and every request-path rule keyed by its `model_type` reads it
/// here, never from its own string.
///
/// Exact-artifact lists use `matches(modelId:modelType:)`. Rules that follow
/// the model's wire protocol (template context, output channels, tool frames,
/// stop tokens) use `isModelType`: any artifact of the type speaks it.
///
/// This grants nothing by itself. Admission to the engine's supported set,
/// runtime capability, cache security and admission floors stay separate.
public enum MuseGlimmerModelPolicy {
    /// Working catalog identity. A placeholder until the owner names the
    /// listing; renaming it is a change to this line only.
    public static let catalogModelID = "muse-glimmer-30b"

    /// The pinned NVIDIA NVFP4 download as a local Hugging Face cache names it.
    public static let localModelID = "nvidia/Muse-Glimmer-30B-NVFP4"

    public static let modelType = "muse_glimmer"

    /// The checkpoint's trained context (`max_position_embeddings`).
    public static let contextTokens = 131_072

    /// ModelOpt mixed precision led by NVFP4 weights; the scan reports it.
    public static let quantizationLabel = "nvfp4"

    /// The deepest draft a row may take: the engine's tested window.
    public static let maximumDraftTokens = 7

    public static func matchesModelID(_ id: String?) -> Bool {
        id == catalogModelID || id == localModelID
    }

    public static func isModelType(_ modelType: String?) -> Bool {
        modelType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == Self.modelType
    }

    public static func matches(modelId: String?, modelType: String?) -> Bool {
        matchesModelID(modelId) && isModelType(modelType)
    }

    /// The context a slot advertises: the trained window, never more than the
    /// loaded model's own bound. Nil for any other model.
    public static func contextLimit(
        modelId: String?, modelType: String?, nativeContextTokens: Int
    ) -> Int? {
        guard matches(modelId: modelId, modelType: modelType), nativeContextTokens > 0 else { return nil }
        return min(contextTokens, nativeContextTokens)
    }
}
