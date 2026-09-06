import Foundation

enum ModelScope: String, CaseIterable, Identifiable {
    case installed
    case discover

    var id: String { rawValue }
    var title: String { self == .installed ? "Installed" : "Discover" }
}

struct CompatibilityConfirmation {
    let modelID: ModelSummary.ID
    let requiredMemoryGB: Int
    let availableMemoryGB: Int
}

struct ModelLibraryCollection {
    let recommendation: ModelSummary?
    let catalogModels: [ModelSummary]
    let otherLocalModels: [ModelSummary]
    let transfers: [ModelSummary]

    var isEmpty: Bool {
        recommendation == nil && catalogModels.isEmpty && otherLocalModels.isEmpty && transfers.isEmpty
    }
}

enum ModelLibraryPresentation {
    static func allowsTransientSelection(isLive: Bool) -> Bool {
        !isLive
    }

    static func displayedModels(
        from models: [ModelSummary],
        scope: ModelScope,
        search: String = ""
    ) -> [ModelSummary] {
        let scoped: [ModelSummary] = switch scope {
        case .installed:
            models.filter {
                $0.isInstalled || $0.installation.progress != nil || isFailure($0.installation)
            }
        case .discover:
            models
                .filter(\.isAvailableFromCatalog)
        }
        return scoped.filter { matchesSearch($0, search: search) }.sorted(by: collectionOrder)
    }

    static func collection(
        from models: [ModelSummary],
        scope: ModelScope,
        search: String,
        catalogState: ModelCatalogState
    ) -> ModelLibraryCollection {
        let scoped = displayedModels(from: models, scope: scope, search: search)
        let recommendation = search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (recommendedModel(from: scoped, catalogState: catalogState)
                ?? recommendedModel(from: models, catalogState: catalogState))
            : nil
        let rows = scoped.filter { !isActiveTransfer($0.installation) && $0.id != recommendation?.id }
        return ModelLibraryCollection(
            recommendation: recommendation,
            catalogModels: rows.filter(\.isAvailableFromCatalog),
            otherLocalModels: rows.filter { !$0.isAvailableFromCatalog },
            transfers: models.filter {
                isActiveTransfer($0.installation) && matchesSearch($0, search: search)
            }.sorted(by: collectionOrder)
        )
    }

    /// `.fits` is projected from the CLI's runtime verdict and memory check.
    /// Unknown compatibility (even when locally usable) is not a recommendation.
    /// Prefer an installed option, then the smallest known download footprint.
    /// Names break ties; storage size is not a proxy for speed or quality.
    static func recommendedModel(
        from models: [ModelSummary],
        catalogState: ModelCatalogState
    ) -> ModelSummary? {
        guard case .available = catalogState else { return nil }
        return models.filter { model in
            guard model.isAvailableFromCatalog, model.fit == .fits, model.sizeBytes > 0,
                  model.supportsChat, model.runtime != .crashed
            else { return false }
            switch model.installation {
            case .installed, .notInstalled: return true
            case .downloading, .paused, .verifying, .failed: return false
            }
        }.sorted(by: recommendationOrder).first
    }

    private static func matchesSearch(_ model: ModelSummary, search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return [model.displayName, model.id, model.summary, model.family ?? ""]
            .contains { $0.localizedStandardContains(query) }
            || model.capabilities.contains { $0.displayName.localizedStandardContains(query) }
    }

    static func activeTransferSignature(for models: [ModelSummary]) -> String {
        models.map { model in
            "\(model.id):\(transferPhase(for: model.installation))"
        }.joined(separator: "|")
    }

    static func actionErrorMessage(for result: ModelLibraryActionResult?) -> String? {
        switch result {
        case .unavailable(let message): message
        case .invalidState: "The model changed state before that action could finish. Refresh and try again."
        case .modelNotFound: "Darkbloom can no longer find that model."
        case .requiresCompatibilityConfirmation, .applied, nil: nil
        }
    }

    private static func isFailure(_ installation: ModelInstallationState) -> Bool {
        if case .failed = installation { return true }
        return false
    }

    private static func isActiveTransfer(_ installation: ModelInstallationState) -> Bool {
        switch installation {
        case .downloading, .paused, .verifying: true
        case .notInstalled, .installed, .failed: false
        }
    }

    private static func collectionOrder(_ lhs: ModelSummary, _ rhs: ModelSummary) -> Bool {
        let left = compatibilityRank(lhs.fit)
        let right = compatibilityRank(rhs.fit)
        return left == right ? nameOrder(lhs, rhs) : left < right
    }

    private static func recommendationOrder(_ lhs: ModelSummary, _ rhs: ModelSummary) -> Bool {
        if lhs.isInstalled != rhs.isInstalled { return lhs.isInstalled }
        if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes < rhs.sizeBytes }
        return nameOrder(lhs, rhs)
    }

    private static func nameOrder(_ lhs: ModelSummary, _ rhs: ModelSummary) -> Bool {
        let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
        return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
    }

    private static func compatibilityRank(_ fit: ModelFit) -> Int {
        switch fit {
        case .fits: 0
        case .unknown, .runtimeUnknown: 1
        case .tooLarge: 2
        case .runtimeIneligible: 3
        }
    }

    private static func transferPhase(for installation: ModelInstallationState) -> String {
        switch installation {
        case .notInstalled: "not-installed"
        case .downloading: "downloading"
        case .paused: "paused"
        case .verifying: "verifying"
        case .installed: "installed"
        case .failed: "failed"
        }
    }
}
