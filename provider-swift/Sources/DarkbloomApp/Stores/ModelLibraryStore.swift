import Foundation
import Observation

enum ModelCatalogState: Equatable, Sendable {
    case loading
    case available(lastUpdated: Date)
    case offline(message: String, showingCachedResults: Bool)
}

enum ModelLibraryFixture: String, CaseIterable, Sendable {
    case ready
    case catalogOffline
    case tooLarge
    case resumableDownload
    case failedVerification
}

enum ModelLibraryActionResult: Equatable, Sendable {
    case applied
    case requiresCompatibilityConfirmation(requiredMemoryGB: Int, availableMemoryGB: Int)
    case unavailable(String)
    case invalidState
    case modelNotFound
}

@MainActor
@Observable
final class ModelLibraryStore {
    private(set) var catalogState: ModelCatalogState
    private(set) var models: [ModelSummary]
    private(set) var selectedModelID: ModelSummary.ID?
    private(set) var lastActionResult: ModelLibraryActionResult?

    init(fixture: ModelLibraryFixture = .ready) {
        let state = ModelLibraryFixtures.make(fixture)
        catalogState = state.catalogState
        models = state.models
        selectedModelID = state.selectedModelID
    }

    var selectedModel: ModelSummary? {
        guard let selectedModelID else { return nil }
        return models.first { $0.id == selectedModelID }
    }

    var installedModels: [ModelSummary] {
        models.filter(\.isInstalled)
    }

    var activeTransfers: [ModelSummary] {
        models.filter {
            switch $0.installation {
            case .downloading, .paused, .verifying: true
            case .notInstalled, .installed, .failed: false
            }
        }
    }

    func selectModel(id: ModelSummary.ID?) {
        guard id == nil || models.contains(where: { $0.id == id }) else {
            lastActionResult = .modelNotFound
            return
        }
        selectedModelID = id
        lastActionResult = .applied
    }

    func retryCatalog() {
        catalogState = .available(lastUpdated: ModelLibraryFixtures.timestamp)
        lastActionResult = .applied
    }

    func clearLastActionResult() {
        lastActionResult = nil
    }

    @discardableResult
    func beginDownload(
        modelID: ModelSummary.ID,
        allowingIncompatibleModel: Bool = false
    ) -> ModelLibraryActionResult {
        guard let index = index(of: modelID) else {
            return record(.modelNotFound)
        }

        guard models[index].isAvailableFromCatalog else {
            return record(.unavailable("This model is not available in the current catalog."))
        }

        if case .loading = catalogState {
            return record(.unavailable("Wait for the catalog to finish loading."))
        }

        if case .offline = catalogState {
            return record(.unavailable("Reconnect to refresh the catalog before downloading."))
        }

        if case .tooLarge(let required, let available) = models[index].fit,
           !allowingIncompatibleModel {
            return record(.requiresCompatibilityConfirmation(
                requiredMemoryGB: required,
                availableMemoryGB: available
            ))
        }

        switch models[index].installation {
        case .notInstalled:
            let progress = ModelTransferProgress(
                downloadedBytes: 0,
                totalBytes: models[index].sizeBytes,
                bytesPerSecond: ModelLibraryFixtures.transferRate
            )
            models[index].installation = .downloading(progress)
            return record(.applied)

        case .failed(let failure):
            let progress = failure.isResumable
                ? failure.resumableProgress ?? emptyProgress(for: models[index])
                : emptyProgress(for: models[index])
            models[index].installation = .downloading(progress)
            return record(.applied)

        case .downloading, .paused, .verifying, .installed:
            return record(.invalidState)
        }
    }

    @discardableResult
    func pauseDownload(modelID: ModelSummary.ID) -> ModelLibraryActionResult {
        guard let index = index(of: modelID) else { return record(.modelNotFound) }
        guard case .downloading(let progress) = models[index].installation else {
            return record(.invalidState)
        }
        models[index].installation = .paused(progress)
        return record(.applied)
    }

    @discardableResult
    func resumeDownload(modelID: ModelSummary.ID) -> ModelLibraryActionResult {
        guard let index = index(of: modelID) else { return record(.modelNotFound) }

        let progress: ModelTransferProgress
        switch models[index].installation {
        case .paused(let pausedProgress):
            progress = pausedProgress
        case .failed(let failure) where failure.isResumable:
            guard let resumableProgress = failure.resumableProgress else {
                return record(.invalidState)
            }
            progress = resumableProgress
        default:
            return record(.invalidState)
        }

        models[index].installation = .downloading(progress)
        return record(.applied)
    }

    @discardableResult
    func advanceDownload(modelID: ModelSummary.ID) -> ModelLibraryActionResult {
        guard let index = index(of: modelID) else { return record(.modelNotFound) }
        guard case .downloading(let current) = models[index].installation else {
            return record(.invalidState)
        }

        let increment = max(1, current.totalBytes / 4)
        let downloaded = min(current.totalBytes, current.downloadedBytes + increment)
        let remaining = max(0, current.totalBytes - downloaded)
        let eta = ModelLibraryFixtures.transferRate > 0
            ? Int(ceil(Double(remaining) / Double(ModelLibraryFixtures.transferRate)))
            : nil
        let next = ModelTransferProgress(
            downloadedBytes: downloaded,
            totalBytes: current.totalBytes,
            bytesPerSecond: ModelLibraryFixtures.transferRate,
            estimatedSecondsRemaining: eta,
            resumedBytes: current.resumedBytes
        )

        models[index].installation = downloaded == current.totalBytes
            ? .verifying(next)
            : .downloading(next)
        return record(.applied)
    }

    @discardableResult
    func finishVerification(
        modelID: ModelSummary.ID,
        succeeds: Bool
    ) -> ModelLibraryActionResult {
        guard let index = index(of: modelID) else { return record(.modelNotFound) }
        guard case .verifying = models[index].installation else {
            return record(.invalidState)
        }

        if succeeds {
            models[index].installation = .installed
        } else {
            models[index].installation = .failed(ModelTransferFailure(
                reason: .verificationMismatch,
                message: "The downloaded weights did not match the catalog hash.",
                resumableProgress: nil
            ))
        }
        return record(.applied)
    }

    @discardableResult
    func removeModel(modelID: ModelSummary.ID) -> ModelLibraryActionResult {
        guard let index = index(of: modelID) else { return record(.modelNotFound) }
        guard models[index].isInstalled else { return record(.invalidState) }
        guard models[index].runtime == .cold else {
            return record(.unavailable("Take this model offline before removing it."))
        }
        if models[index].origin == .localOnly {
            let removedID = models[index].id
            models.remove(at: index)
            if selectedModelID == removedID { selectedModelID = nil }
        } else {
            models[index].installation = .notInstalled
        }
        return record(.applied)
    }

    private func index(of modelID: ModelSummary.ID) -> Int? {
        models.firstIndex { $0.id == modelID }
    }

    private func emptyProgress(for model: ModelSummary) -> ModelTransferProgress {
        ModelTransferProgress(
            downloadedBytes: 0,
            totalBytes: model.sizeBytes,
            bytesPerSecond: ModelLibraryFixtures.transferRate
        )
    }

    @discardableResult
    private func record(_ result: ModelLibraryActionResult) -> ModelLibraryActionResult {
        lastActionResult = result
        return result
    }
}
