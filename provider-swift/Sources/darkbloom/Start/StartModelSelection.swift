import ArgumentParser
import Foundation
import ProviderCore

/// The normal picker controls startup preferences. Autopilot consent has its
/// own verified cached inventory; it must not replace the picker result.
struct StartModelSelection {
    let hostedModels: [String]
    let autopilotModels: [String]?
}

extension Start {
    static func prepareModelSelection(
        autopilot: Bool,
        select: () async throws -> [String],
        inventory: ([String]) async throws -> [String]
    ) async throws -> StartModelSelection {
        let hosted = try await select()
        guard !hosted.isEmpty else { throw ValidationError("No models selected.") }
        try Task.checkCancellation()
        let cached = autopilot ? try await inventory(hosted) : nil
        if let cached, !Set(hosted).isSubset(of: Set(cached)) {
            throw ValidationError("The selected startup models could not all be verified for Autopilot. Retry after any model update finishes, or use --no-autopilot.")
        }
        return StartModelSelection(hostedModels: hosted, autopilotModels: cached)
    }

    func selectStartupModels(snapshot: RuntimeSnapshot, config: ProviderConfig,
                             coordinatorURL: String,
                             runtimeCapabilities: Set<ProviderRuntimeCapability>) async throws -> [String] {
        if !model.isEmpty {
            let known = Set(snapshot.models.map(\.id))
            return model.filter {
                known.contains($0) && ModelRuntimeRequirements.isEligible(modelID: $0, available: runtimeCapabilities)
            }
        }
        if all {
            return snapshot.models.compactMap {
                ModelRuntimeRequirements.isEligible(modelID: $0.id, available: runtimeCapabilities) ? $0.id : nil
            }
        }
        return try await interactiveCatalogPicker(snapshot: snapshot, config: config,
            coordinatorURL: coordinatorURL, runtimeCapabilities: runtimeCapabilities)
    }
}
