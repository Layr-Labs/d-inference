import ProviderCore

/// Projects operator configuration into construction inputs and checks the
/// independent precision observations returned by the measured engines.
enum SchedulerPrefillDecisionKVProvenance {
    static func environment(
        modelType: String?, modelID: String,
        global: String, byModel: [String: String],
        environment: [String: String]
    ) throws -> [String: String] {
        let precision = try EngineV2KVQuantizationPolicy.resolve(
            modelType: modelType, global: global, byModel: byModel,
            modelID: modelID, environment: environment)
        var resolved = environment
        resolved[EngineV2KVQuantizationPolicy.environmentKey] = precision.rawValue
        return resolved
    }

    static func runPrecision(
        results: [SchedulerPrefillDecisionReport.Result]
    ) -> String? {
        let profiles = results.compactMap(\.resolvedKVQuantization)
        guard !results.isEmpty, profiles.count == results.count,
            Set(profiles).count == 1
        else { return nil }
        return profiles.first
    }

    static func isConsistent(
        results: [SchedulerPrefillDecisionReport.Result],
        reproducibility: SchedulerPrefillDecisionReport.Reproducibility?
    ) -> Bool {
        guard let observed = runPrecision(results: results),
            let profile = EngineV2KVQuantizationSelection(rawValue: observed),
            reproducibility?.resolvedKVQuantization == observed
        else { return false }
        return results.allSatisfy { result in
            switch result.resolvedKVBackend?.split(separator: " ").first {
            case "paged": true
            case "contiguous": profile == .native
            default: false
            }
        }
    }
}
