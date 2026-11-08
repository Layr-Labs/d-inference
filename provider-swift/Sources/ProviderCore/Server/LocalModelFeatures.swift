import Foundation

/// `supported_features` in this Mac's `/v1/models`, in the coordinator's names: `reasoning` for a model that reasons
/// and nothing else, an empty list for one that doesn't. A model reasons when its type's template does, by the table
/// that takes every reasoning effort for it and refuses one that is none of the names
/// (`ReasoningEffortPolicy.reasons`), so the list and the API never disagree. The one place the provider says which of
/// the models it serves reason (one Mac, a pair's slot), and where the integrations read it back. Tools, JSON output
/// and the rest stay the catalog's.
public enum LocalModelFeatures {
    public static let reasoning = "reasoning"

    /// `["reasoning"]` for a model that reasons, else none.
    static func list(reasons: Bool) -> [String] { reasons ? [reasoning] : [] }

    /// Whether a model this Mac serves reasons, by its type (the `model_type` it registers, or a pair's installed
    /// one); nil when its type isn't known here.
    static func reasons(modelID: String, modelType: String?) -> Bool? {
        modelType.map { ReasoningEffortPolicy.reasons(modelID: modelID, modelType: $0) }
    }

    /// A model whose list entry names `reasoning` among its `supported_features` (in any case).
    public static func listsReasoning(_ features: [String]?) -> Bool {
        features?.contains { $0.lowercased() == reasoning } == true
    }
}
