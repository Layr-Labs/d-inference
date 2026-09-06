import Foundation
import ProviderCoreFoundation

/// Pure projection of CLI inventory, eligibility, and cached transfer state.
enum ModelLibrarySnapshotMapping {
    /// Rebuild rows from a live snapshot. In-flight installation states
    /// (downloading/paused/verifying/failed) are PRESERVED: a staged
    /// download is invisible to the scanner, so the snapshot can't see it.
    /// The one exception: once the local scan contains the model, disk truth
    /// wins (publish racing the stream has resolved as success).
    static func rows(snapshot: ModelLibrarySnapshot, existingModels: [ModelSummary]) -> [ModelSummary] {
        let localIDs = Set(snapshot.local.map(\.id))
        let existingByID = Dictionary(existingModels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var rows: [ModelSummary] = snapshot.catalog.map { entry in
            let installed = localIDs.contains(entry.id)
            var installation: ModelInstallationState = installed ? .installed : .notInstalled
            if !installed, let preserved = Self.preservedTransferState(of: existingByID[entry.id]) {
                installation = preserved
            }
            return ModelSummary(
                id: entry.id,
                displayName: entry.displayName,
                family: entry.family,
                kind: Self.kind(for: entry.modelType),
                summary: entry.description ?? "",
                sizeBytes: ModelCatalogSize.bytes(
                    totalSizeBytes: entry.totalSizeBytes,
                    sizeGB: entry.sizeGb
                ),
                minimumMemoryGB: entry.minRamGb,
                quantization: entry.quantization,
                maxContextLength: entry.maxContextLength,
                capabilities: (entry.capabilities ?? []).map(ModelCapability.init(rawValue:)),
                origin: .catalog,
                fit: Self.fit(for: entry, snapshot: snapshot, cachedFit: existingByID[entry.id]?.fit),
                installation: installation,
                runtime: Self.runtime(for: entry.id, snapshot: snapshot)
            )
        }

        if snapshot.catalogError != nil {
            // Keep catalog metadata and CLI-owned eligibility during an outage,
            // but replace installation/warmth with this refresh's local truth.
            rows = existingModels.filter {
                $0.isAvailableFromCatalog || localIDs.contains($0.id)
                    || Self.preservedTransferState(of: $0) != nil
            }.map { existing in
                var model = existing
                model.installation = localIDs.contains(model.id)
                    ? .installed
                    : Self.preservedTransferState(of: existing) ?? .notInstalled
                model.runtime = Self.runtime(for: model.id, snapshot: snapshot)
                return model
            }
        }

        let representedIDs = Set(rows.map(\.id))
        rows += snapshot.local
            .filter { !representedIDs.contains($0.id) }
            .map { entry in
                ModelSummary(
                    id: entry.id,
                    displayName: entry.id.split(separator: "/").last.map(String.init) ?? entry.id,
                    family: nil,
                    kind: Self.kind(for: entry.modelType),
                    summary: "A model discovered locally that is not in the active catalog.",
                    sizeBytes: Int64(clamping: entry.sizeBytes),
                    minimumMemoryGB: nil,
                    quantization: entry.quantization,
                    maxContextLength: nil,
                    capabilities: [],
                    origin: .localOnly,
                    fit: existingByID[entry.id]?.fit ?? .unknown,
                    installation: .installed,
                    runtime: Self.runtime(for: entry.id, snapshot: snapshot)
                )
            }

        return rows
    }

    private static func preservedTransferState(of model: ModelSummary?) -> ModelInstallationState? {
        guard let model else { return nil }
        switch model.installation {
        case .downloading, .paused, .verifying, .failed:
            return model.installation
        case .notInstalled, .installed:
            return nil
        }
    }

    private static func kind(for modelType: String?) -> ModelKind {
        switch modelType?.lowercased() {
        case "text": .text
        case "vision", "vlm", "multimodal": .vision
        case "embeddings", "embedding": .embeddings
        default: .unknown
        }
    }

    private static func fit(
        for entry: CLICatalogModel,
        snapshot: ModelLibrarySnapshot,
        cachedFit: ModelFit?
    ) -> ModelFit {
        let runtime = snapshot.runtimeEligibility(for: entry.id)
        switch runtime.status {
        case .ineligible: return .runtimeIneligible(reason: runtime.reason)
        case .unknown:
            // Missing metadata is not evidence that a prior CLI refusal changed.
            if let cachedFit, case .runtimeIneligible = cachedFit { return cachedFit }
            return .runtimeUnknown(reason: runtime.reason)
        case .eligible: break
        }
        guard let required = entry.minRamGb, let available = snapshot.physicalMemoryGB else { return .unknown }
        return required <= available
            ? .fits
            : .tooLarge(requiredMemoryGB: required, availableMemoryGB: available)
    }

    private static func runtime(for modelID: String, snapshot: ModelLibrarySnapshot) -> ModelRuntimeState {
        if snapshot.servingModelID == modelID { return .serving }
        if snapshot.warmModelIDs.contains(modelID) { return .warm }
        return .cold
    }

}
