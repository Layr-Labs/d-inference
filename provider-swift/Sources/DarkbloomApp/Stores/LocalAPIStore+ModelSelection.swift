import Foundation

extension LocalAPIStore {
    /// Models -> Use locally hands off selection only. An explicit unavailable
    /// choice clears the selector instead of silently starting a different model.
    /// Re-evaluated after inventory/eligibility changes, with no process side effect.
    func syncLocalModelSelection(preferredID: String?, models: [ModelSummary]) {
        if let preferredID {
            selectedLocalModelID = eligibleLocalModel(preferredID, in: models) ? preferredID : nil
            return
        }
        if let selectedLocalModelID, eligibleLocalModel(selectedLocalModelID, in: models) { return }
        // Prefer a compatible, lighter installed model for the first session.
        // Unclassified local files (including speech/embedding models) require
        // an explicit choice. The same CLI preflight remains authoritative.
        selectedLocalModelID = models
            .filter { $0.fit == .fits && $0.supportsChat
                && eligibleLocalModel($0.id, in: models) }
            .sorted { lhs, rhs in
                let leftSize = lhs.sizeBytes > 0 ? lhs.sizeBytes : Int64.max
                let rightSize = rhs.sizeBytes > 0 ? rhs.sizeBytes : Int64.max
                return leftSize == rightSize ? lhs.id < rhs.id : leftSize < rightSize
            }.first?.id
    }

    private func eligibleLocalModel(_ id: String, in models: [ModelSummary]) -> Bool {
        do {
            // Source provenance is checked at launch; fixture selectors remain
            // interactive without ever being permitted to run real commands.
            try LocalAPIStartPreflight.validateModel(modelID: id, models: models, modelsAreLive: true)
            return true
        } catch { return false }
    }
}
