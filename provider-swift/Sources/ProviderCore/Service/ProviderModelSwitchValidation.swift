import Foundation

/// Resolves only real local snapshots. The scanner's complete load estimate is
/// retained; advertising a synthetic/zero-size model bypasses memory admission.
public enum ProviderModelSwitchValidation {
    internal struct Result: Sendable {
        let models: [ModelInfo]
        let fingerprints: [String: String]
    }

    /// Only the result wait is cancellable: an OS read already in progress may
    /// finish later, but the detached worker owns no provider state or receipts.
    internal static func scanCancellable(
        _ modelIDs: [String], capabilities: Set<ProviderRuntimeCapability>,
        resolveSnapshot: @escaping @Sendable (String) -> URL?,
        hashSnapshot: @escaping @Sendable (URL, String) -> String?
    ) async throws -> Result {
        let (results, continuation) = AsyncThrowingStream<Result, Error>.makeStream()
        let worker = Task.detached(priority: .utility) {
            do {
                let selection = try scanSnapshots(modelIDs, capabilities: capabilities,
                    resolveSnapshot: resolveSnapshot, hashSnapshot: hashSnapshot, captureFingerprints: true)
                continuation.yield(selection)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        defer { worker.cancel() }
        for try await selection in results {
            try Task.checkCancellation()
            return selection
        }
        throw CancellationError()
    }

    public static func scan(
        _ modelIDs: [String], capabilities: Set<ProviderRuntimeCapability>,
        resolveSnapshot: @Sendable (String) -> URL? = { ModelScanner.resolveLocalPath(modelID: $0) },
        hashSnapshot: @Sendable (URL, String) -> String? = { WeightHasher.computeHash(snapshotDir: $0, modelID: $1) }
    ) throws -> [ModelInfo] {
        try scanSnapshots(modelIDs, capabilities: capabilities,
            resolveSnapshot: resolveSnapshot, hashSnapshot: hashSnapshot, captureFingerprints: false).models
    }

    private static func scanSnapshots(
        _ modelIDs: [String], capabilities: Set<ProviderRuntimeCapability>,
        resolveSnapshot: @Sendable (String) -> URL?,
        hashSnapshot: @Sendable (URL, String) -> String?,
        captureFingerprints: Bool
    ) throws -> Result {
        guard !modelIDs.isEmpty, Set(modelIDs).count == modelIDs.count else {
            throw ModelSelectionFailure("Select at least one model, without duplicate IDs.")
        }
        var fingerprints: [String: String] = [:]
        let models = try modelIDs.map { id in
            try Task.checkCancellation()
            try ModelRuntimeRequirements.requireEligible(modelID: id, available: capabilities)
            guard let path = resolveSnapshot(id),
                  var model = ModelScanner.parseModelInfo(snapshotDir: path, modelName: id) else {
                throw ModelSelectionFailure("Model '\(id)' is not downloaded or cannot be scanned. Use darkbloom models download first.")
            }
            guard EngineV2SupportedModels.isSupported(model: model), model.templateRenderOK != false else {
                throw ModelSelectionFailure("Model '\(id)' has an unsupported engine or a failing chat template.")
            }
            guard model.estimatedMemoryGb.isFinite, model.estimatedMemoryGb > 0 else {
                throw ModelSelectionFailure("Model '\(id)' has no valid load estimate or verified weight hash.")
            }
            // Capture before hashing: a change during the read must invalidate
            // the next load's cache, not pair new metadata with an older hash.
            let fingerprint = captureFingerprints ? WeightHasher.snapshotFingerprint(snapshotDir: path) : nil
            guard let hash = hashSnapshot(path, id), !hash.isEmpty else {
                throw ModelSelectionFailure("Model '\(id)' has no valid load estimate or verified weight hash.")
            }
            model.weightHash = hash
            if let fingerprint { fingerprints[id] = fingerprint }
            return model
        }
        return Result(models: models, fingerprints: fingerprints)
    }
}
