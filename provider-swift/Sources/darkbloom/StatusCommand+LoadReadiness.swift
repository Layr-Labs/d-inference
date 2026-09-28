import Foundation
import ProviderCore

extension Status {
    /// Use only a recent daemon sample. A cold model and stale memory figures
    /// must never become a confident "cannot load" verdict.
    static func liveLoadReadiness(
        state: DaemonState, models: [ModelInfo], now: Double,
        heartbeatIntervalSecs: UInt64
    ) -> [String: ModelLoadReadiness] {
        guard state.ageSeconds(now: now) <= KVBackendPosture.staleAfterSeconds(
            heartbeatIntervalSecs: heartbeatIntervalSecs),
            let usable = state.capacity?.loadUsableGb,
            let headroom = state.capacity?.loadHeadroomGb else { return [:] }
        var result: [String: ModelLoadReadiness] = [:]
        for model in models {
            result[model.id] = ModelLoadReadiness(
                estimatedMemoryGb: model.estimatedMemoryGb,
                headroomGb: headroom, usableGb: usable)
        }
        return result
    }
}
