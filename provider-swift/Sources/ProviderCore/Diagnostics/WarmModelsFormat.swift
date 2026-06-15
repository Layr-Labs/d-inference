import Foundation

/// Pure, platform-agnostic formatting for the provider's resident-model display
/// in `darkbloom status` and `darkbloom doctor`.
///
/// Routing has always been per-model: a provider keeps every resident model warm
/// in its own LRU slot and serves any of them. The daemon state file already
/// carries the full set (`warmModels`) plus the single most-recently-used slot
/// (`currentModel`, the newest `lastInferenceAt`). The CLI historically printed
/// only the single value and mislabeled it "Current model", implying the box
/// served just one. These helpers render the full resident set and relabel the
/// single value as "Most recently used" so the display matches reality.
public enum WarmModelsFormat {
    /// The label for the single LRU value. Renamed from "Current model" because
    /// it is the most-recently-used slot, not the only model this box serves.
    public static let mostRecentlyUsedLabel = "Most recently used"

    /// One-line list of every resident (warm) model, e.g.
    /// "gemma-4-26b, gpt-oss-20b". Falls back to `currentModel` when the warm
    /// set is empty (older daemons predating the `warm_models` field), and to
    /// `emptyPlaceholder` when nothing is loaded.
    public static func warmModelsLine(
        warmModels: [String],
        currentModel: String?,
        emptyPlaceholder: String = "none loaded"
    ) -> String {
        let resident = residentModels(warmModels: warmModels, currentModel: currentModel)
        return resident.isEmpty ? emptyPlaceholder : resident.joined(separator: ", ")
    }

    /// The most-recently-used model, or `emptyPlaceholder` when nothing loaded.
    public static func mostRecentlyUsedLine(
        currentModel: String?,
        emptyPlaceholder: String = "none loaded"
    ) -> String {
        guard let current = currentModel, !current.isEmpty else { return emptyPlaceholder }
        return current
    }

    /// The de-duplicated resident set. Prefers `warmModels`; if that is empty,
    /// falls back to the single `currentModel` (back-compat with daemons that
    /// don't populate `warmModels`).
    static func residentModels(warmModels: [String], currentModel: String?) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for model in warmModels where !model.isEmpty && seen.insert(model).inserted {
            result.append(model)
        }
        if result.isEmpty, let current = currentModel, !current.isEmpty {
            result.append(current)
        }
        return result
    }
}
