import ProviderCore

/// Pick the model whose cold-load readiness the operator needs diagnosed.
/// A recently used resident slot must not hide a different selected model
/// that failed to load.
enum DoctorModelSelection {
    /// Diagnose every advertised cold model, largest first so the first
    /// actionable failure reports the greatest load-memory shortfall.
    static func diagnosticTargets(
        state: DaemonState?, stateFresh: Bool,
        localModels: [ModelFitDiagnostic.ModelOption], fallback: String?
    ) -> [ModelFitDiagnostic.ModelOption] {
        let byID = Dictionary(localModels.map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        if stateFresh, let state {
            let cold = (state.advertisedModels ?? [])
                .compactMap { byID[$0] }
                .filter { !isResident($0.id, state: state) }
                .sorted { $0.weightGb > $1.weightGb }
            if !cold.isEmpty { return cold }
        }
        if let target = preferredTarget(
            state: state, stateFresh: stateFresh,
            localModelIDs: Set(byID.keys), fallback: fallback),
           let model = byID[target] {
            return [model]
        }
        return localModels.max(by: { $0.weightGb < $1.weightGb }).map { [$0] } ?? []
    }

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
