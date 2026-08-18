import Testing
@testable import DarkbloomApp

@Test("An offline catalog keeps cached models visible and blocks new downloads")
@MainActor
func offlineCatalogUsesCachedModels() {
    let store = ModelLibraryStore(fixture: .catalogOffline)

    guard case .offline(_, let showingCachedResults) = store.catalogState else {
        Issue.record("Expected an offline catalog")
        return
    }
    #expect(showingCachedResults)
    #expect(!store.installedModels.isEmpty)

    let model = store.models.first { !$0.isInstalled && $0.isAvailableFromCatalog }
    #expect(model != nil)
    #expect(store.beginDownload(modelID: model?.id ?? "missing") == .unavailable(
        "Reconnect to refresh the catalog before downloading."
    ))

    store.retryCatalog()
    guard case .available = store.catalogState else {
        Issue.record("Retry should restore the deterministic catalog fixture")
        return
    }
}

@Test("A model that exceeds available memory requires an explicit confirmation")
@MainActor
func incompatibleModelRequiresConfirmation() {
    let store = ModelLibraryStore(fixture: .tooLarge)
    let modelID = store.selectedModelID ?? "missing"

    #expect(store.beginDownload(modelID: modelID) == .requiresCompatibilityConfirmation(
        requiredMemoryGB: 48,
        availableMemoryGB: 32
    ))
    #expect(store.beginDownload(
        modelID: modelID,
        allowingIncompatibleModel: true
    ) == .applied)

    guard case .downloading(let progress) = store.selectedModel?.installation else {
        Issue.record("Confirmed download should enter the downloading state")
        return
    }
    #expect(progress.downloadedBytes == 0)
}

@Test("A byte-resumable download preserves its prefix and reaches verification")
@MainActor
func resumableDownloadPreservesProgress() {
    let store = ModelLibraryStore(fixture: .resumableDownload)
    let modelID = store.selectedModelID ?? "missing"

    guard case .paused(let paused) = store.selectedModel?.installation else {
        Issue.record("Expected a paused fixture")
        return
    }
    #expect(paused.isResumed)
    #expect(paused.fractionComplete > 0.4)

    #expect(store.resumeDownload(modelID: modelID) == .applied)
    #expect(store.advanceDownload(modelID: modelID) == .applied)

    guard case .downloading(let advanced) = store.selectedModel?.installation else {
        Issue.record("The first deterministic tick should still be downloading")
        return
    }
    #expect(advanced.downloadedBytes > paused.downloadedBytes)
    #expect(advanced.resumedBytes == paused.resumedBytes)

    #expect(store.advanceDownload(modelID: modelID) == .applied)
    #expect(store.advanceDownload(modelID: modelID) == .applied)
    guard case .verifying = store.selectedModel?.installation else {
        Issue.record("Completed bytes should transition to verification")
        return
    }
    #expect(store.finishVerification(modelID: modelID, succeeds: true) == .applied)
    #expect(store.selectedModel?.isInstalled == true)
}

@Test("A verification mismatch starts a clean download instead of resuming corrupt bytes")
@MainActor
func verificationMismatchRestartsCleanly() {
    let store = ModelLibraryStore(fixture: .failedVerification)
    let modelID = store.selectedModelID ?? "missing"

    guard case .failed(let failure) = store.selectedModel?.installation else {
        Issue.record("Expected a failed verification fixture")
        return
    }
    #expect(failure.reason == .verificationMismatch)
    #expect(!failure.isResumable)

    #expect(store.beginDownload(modelID: modelID) == .applied)
    guard case .downloading(let progress) = store.selectedModel?.installation else {
        Issue.record("A retry should start a clean transfer")
        return
    }
    #expect(progress.downloadedBytes == 0)
    #expect(progress.resumedBytes == 0)
}

@Test("Models currently warm or serving cannot be removed")
@MainActor
func activeModelRemovalIsBlocked() {
    let store = ModelLibraryStore()
    let warmModel = store.models.first { $0.runtime == .warm }
    let localColdModel = store.models.first { $0.origin == .localOnly }

    #expect(store.removeModel(modelID: warmModel?.id ?? "missing") == .unavailable(
        "Take this model offline before removing it."
    ))
    #expect(store.removeModel(modelID: localColdModel?.id ?? "missing") == .applied)
    #expect(!store.models.contains { $0.id == localColdModel?.id })
}
