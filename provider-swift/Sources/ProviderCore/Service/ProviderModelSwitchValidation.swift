import Foundation

/// Resolves only real local snapshots. The scanner's complete load estimate is
/// retained; advertising a synthetic/zero-size model bypasses memory admission.
public enum ProviderModelSwitchValidation {
    public static func scan(_ modelIDs: [String], capabilities: Set<ProviderRuntimeCapability>) throws -> [ModelInfo] {
        guard !modelIDs.isEmpty, Set(modelIDs).count == modelIDs.count else {
            throw ModelSelectionFailure("Select at least one model, without duplicate IDs.")
        }
        return try modelIDs.map { id in
            try Task.checkCancellation()
            try ModelRuntimeRequirements.requireEligible(modelID: id, available: capabilities)
            guard let path = ModelScanner.resolveLocalPath(modelID: id),
                  var model = ModelScanner.parseModelInfo(snapshotDir: path, modelName: id) else {
                throw ModelSelectionFailure("Model '\(id)' is not downloaded or cannot be scanned. Use darkbloom models download first.")
            }
            guard EngineV2SupportedModels.isSupported(model: model), model.templateRenderOK != false else {
                throw ModelSelectionFailure("Model '\(id)' has an unsupported engine or a failing chat template.")
            }
            guard model.estimatedMemoryGb.isFinite, model.estimatedMemoryGb > 0,
                  let hash = WeightHasher.computeHash(snapshotDir: path, modelID: id), !hash.isEmpty else {
                throw ModelSelectionFailure("Model '\(id)' has no valid load estimate or verified weight hash.")
            }
            model.weightHash = hash
            return model
        }
    }
}
