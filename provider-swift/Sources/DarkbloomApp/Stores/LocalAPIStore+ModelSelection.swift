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
        selectedLocalModelID = models.first(where: { eligibleLocalModel($0.id, in: models) })?.id
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
