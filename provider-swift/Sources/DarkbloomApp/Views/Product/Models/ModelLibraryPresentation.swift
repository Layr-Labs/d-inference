import Foundation

enum ModelScope: String, CaseIterable, Identifiable {
    case installed
    case discover

    var id: String { rawValue }
    var title: String { self == .installed ? "On this Mac" : "Discover" }
}

struct CompatibilityConfirmation {
    let modelID: ModelSummary.ID
    let requiredMemoryGB: Int
    let availableMemoryGB: Int
}

enum ModelLibraryPresentation {
    static func displayedModels(
        from models: [ModelSummary],
        scope: ModelScope
    ) -> [ModelSummary] {
        switch scope {
        case .installed:
            models.filter {
                $0.isInstalled || $0.installation.progress != nil || isFailure($0.installation)
            }
        case .discover:
            models
                .filter(\.isAvailableFromCatalog)
                .sorted { compatibilityRank($0.fit) < compatibilityRank($1.fit) }
        }
    }

    static func catalogDetail(for state: ModelCatalogState) -> String {
        switch state {
        case .loading: "Refreshing…"
        case .available: "Compatible models first"
        case .offline: "Cached results"
        }
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

    private static func compatibilityRank(_ fit: ModelFit) -> Int {
        switch fit {
        case .fits: 0
        case .unknown: 1
        case .tooLarge: 2
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
