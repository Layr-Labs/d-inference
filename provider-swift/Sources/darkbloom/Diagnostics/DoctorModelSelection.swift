import ProviderCore

/// Pick the model whose cold-load readiness the operator needs diagnosed.
/// A recently used resident slot must not hide a different selected model
/// that failed to load.
enum DoctorModelSelection {
    static func preferredTarget(
        state: DaemonState?, stateFresh: Bool,
        localModelIDs: Set<String>, fallback: String?
    ) -> String? {
        guard stateFresh, let state else { return fallback }
        let advertised = (state.advertisedModels ?? []).filter(localModelIDs.contains)
        let cold = advertised.filter { !isResident($0, state: state) }
        if let failed = state.lastModelLoadError?.model, cold.contains(failed) {
            return failed
        }
        return cold.first ?? state.currentModel ?? fallback
    }

    static func isResident(_ modelID: String, state: DaemonState) -> Bool {
        if let slots = state.slots {
            return slots.contains {
                $0.model == modelID && $0.loadError == nil && $0.kvBackend != nil
            }
        }
        return state.warmModels.contains(modelID) || state.currentModel == modelID
    }
}
