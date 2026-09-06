import Foundation
import Testing
@testable import DarkbloomApp

@Test("Installed scope preserves resumable and failed model work")
@MainActor
func installedScopePreservesInProgressModels() {
    let pausedStore = ModelLibraryStore(fixture: .resumableDownload)
    let failedStore = ModelLibraryStore(fixture: .failedVerification)

    let pausedModels = ModelLibraryPresentation.displayedModels(
        from: pausedStore.models,
        scope: .installed
    )
    let failedModels = ModelLibraryPresentation.displayedModels(
        from: failedStore.models,
        scope: .installed
    )

    #expect(pausedModels.contains { $0.id == pausedStore.selectedModelID })
    #expect(failedModels.contains { $0.id == failedStore.selectedModelID })
}

@Test("Discovery excludes local-only models and ranks incompatible models last")
@MainActor
func discoveryPreservesCatalogTruth() {
    let store = ModelLibraryStore()
    let discovered = ModelLibraryPresentation.displayedModels(
        from: store.models,
        scope: .discover
    )

    let allModelsAreFromCatalog = discovered.allSatisfy { $0.isAvailableFromCatalog }
    #expect(allModelsAreFromCatalog)
    #expect(discovered.last?.fit.canRunOnThisMac == false)
}

@Test("Search preserves scope and matches names, descriptions, and capabilities")
@MainActor
func modelSearchPreservesScope() {
    let store = ModelLibraryStore()
    let all = ModelLibraryPresentation.displayedModels(from: store.models, scope: .discover)
    #expect(ModelLibraryPresentation.displayedModels(
        from: store.models, scope: .discover, search: "  \n "
    ) == all)
    let qwen = ModelLibraryPresentation.displayedModels(
        from: store.models, scope: .discover, search: "  QWEN  "
    )
    #expect(!qwen.isEmpty)
    #expect(qwen.allSatisfy { $0.displayName.localizedStandardContains("Qwen") })
    let localOnly = store.models.first { !$0.isAvailableFromCatalog }
    if let localOnly {
        #expect(ModelLibraryPresentation.displayedModels(
            from: store.models, scope: .discover, search: localOnly.id
        ).isEmpty)
    }
    #expect(ModelLibraryPresentation.displayedModels(
        from: store.models, scope: .installed, search: "no-such-model-918273"
    ).isEmpty)
}

@Test("Only rejected model actions produce an error message")
func modelActionErrorsRemainSelective() {
    #expect(ModelLibraryPresentation.actionErrorMessage(for: .applied) == nil)
    #expect(ModelLibraryPresentation.actionErrorMessage(
        for: .requiresCompatibilityConfirmation(requiredMemoryGB: 48, availableMemoryGB: 32)
    ) == nil)
    #expect(ModelLibraryPresentation.actionErrorMessage(for: .unavailable("Offline")) == "Offline")
    #expect(ModelLibraryPresentation.actionErrorMessage(for: .modelNotFound) != nil)
}

@Test("Transfer task identity changes by phase, not by every byte tick")
@MainActor
func transferTaskIdentityIsStableWithinPhase() async {
    let store = ModelLibraryStore()
    let modelID = store.models.first { !$0.isInstalled && $0.fit.canRunOnThisMac }?.id ?? "missing"

    #expect(await store.beginDownload(modelID: modelID) == .applied)
    let initialSignature = ModelLibraryPresentation.activeTransferSignature(for: store.activeTransfers)
    #expect(store.advanceDownload(modelID: modelID) == .applied)
    let advancedSignature = ModelLibraryPresentation.activeTransferSignature(for: store.activeTransfers)

    #expect(initialSignature == advancedSignature)

    for _ in 0 ..< 3 {
        _ = store.advanceDownload(modelID: modelID)
    }
    let verifyingSignature = ModelLibraryPresentation.activeTransferSignature(for: store.activeTransfers)
    #expect(verifyingSignature != advancedSignature)
}

@Test("Recommendations require catalog fit and explicit text capability")
func modelRecommendationRequiresEvidence() {
    let available = ModelCatalogState.available(lastUpdated: .distantPast)
    let candidate = libraryPresentationModel(id: "supported", fit: .fits)
    let unknown = libraryPresentationModel(id: "unknown", fit: .unknown)
    let unchecked = libraryPresentationModel(id: "unchecked", fit: .runtimeUnknown(reason: "Not checked"))
    let blocked = libraryPresentationModel(id: "blocked", fit: .runtimeIneligible(reason: "Unsupported"))
    let large = libraryPresentationModel(id: "large", fit: .tooLarge(requiredMemoryGB: 64, availableMemoryGB: 16))
    let local = libraryPresentationModel(id: "local", fit: .fits, origin: .localOnly)
    let missingCapability = libraryPresentationModel(id: "missing-capability", fit: .fits, capabilities: [])
    let embeddings = libraryPresentationModel(id: "embeddings", fit: .fits, capabilities: [.embeddings])
    let unverified = [unknown, unchecked, blocked, large, local, missingCapability, embeddings]

    #expect(ModelLibraryPresentation.recommendedModel(from: unverified, catalogState: available) == nil)
    #expect(ModelLibraryPresentation.recommendedModel(
        from: unverified + [candidate], catalogState: available
    )?.id == candidate.id)
    #expect(ModelLibraryPresentation.recommendedModel(from: [candidate], catalogState: .loading) == nil)
    #expect(ModelLibraryPresentation.recommendedModel(
        from: [candidate], catalogState: .offline(message: "Offline", showingCachedResults: true)
    ) == nil)
}

@Test("Failed and unfinished downloads cannot become recommendations")
func modelRecommendationExcludesUnfinishedWork() {
    let progress = ModelTransferProgress(downloadedBytes: 50, totalBytes: 100)
    let failure = ModelTransferFailure(reason: .verificationMismatch, message: "Failed", resumableProgress: nil)
    let states: [ModelInstallationState] = [.downloading(progress), .paused(progress), .verifying(progress), .failed(failure)]
    let available = ModelCatalogState.available(lastUpdated: .distantPast)
    for state in states {
        let model = libraryPresentationModel(id: "unfinished", fit: .fits, installation: state)
        #expect(ModelLibraryPresentation.recommendedModel(from: [model], catalogState: available) == nil)
    }
    var crashed = libraryPresentationModel(id: "crashed", fit: .fits)
    crashed.runtime = .crashed
    #expect(ModelLibraryPresentation.recommendedModel(from: [crashed], catalogState: available) == nil)
}

@Test("Local models remain searchable regardless of names and are grouped by origin")
func localModelGroupingPreservesEveryIdentity() {
    let localIDs = ["prefetched-3DC2C42E-BFCE-4F13-8572-E012E556DCE0", "unmeasured-5288BA82", "My actual model"]
    let local = localIDs.map { libraryPresentationModel(id: $0, fit: .unknown, origin: .localOnly) }
    let retired = libraryPresentationModel(id: "retired-model", fit: .unknown, origin: .retired)
    let catalog = libraryPresentationModel(id: "catalog-model", fit: .runtimeUnknown(reason: "Not checked"))
    let models = local + [retired, catalog]
    let state = ModelCatalogState.available(lastUpdated: .distantPast)
    let collection = ModelLibraryPresentation.collection(from: models, scope: .installed, search: "", catalogState: state)

    #expect(Set(collection.otherLocalModels.map(\.id)) == Set(localIDs + [retired.id]))
    #expect(collection.catalogModels.map(\.id) == [catalog.id])
    #expect(collection.recommendation == nil)
    for model in local {
        let result = ModelLibraryPresentation.collection(
            from: models, scope: .installed, search: model.id, catalogState: state
        )
        #expect(result.otherLocalModels.map(\.id) == [model.id])
        #expect(!result.isEmpty)
    }
    let discover = ModelLibraryPresentation.collection(from: models, scope: .discover, search: "", catalogState: state)
    #expect(discover.otherLocalModels.isEmpty)
}

@Test("Collections show each transfer once and keep failed work actionable")
func libraryCollectionKeepsTransferAndFailureStates() {
    let progress = ModelTransferProgress(downloadedBytes: 50, totalBytes: 100)
    let transferring = libraryPresentationModel(id: "paused", fit: .fits, installation: .paused(progress))
    let failure = ModelTransferFailure(reason: .network, message: "Reconnect", resumableProgress: progress)
    let failed = libraryPresentationModel(id: "failed", fit: .fits, installation: .failed(failure))
    let collection = ModelLibraryPresentation.collection(
        from: [transferring, failed], scope: .installed, search: "",
        catalogState: .available(lastUpdated: .distantPast)
    )
    #expect(collection.transfers.map(\.id) == [transferring.id])
    #expect(collection.catalogModels.map(\.id) == [failed.id])
    #expect(collection.recommendation == nil)
    #expect(!collection.isEmpty)
}

@Test("A recommendation is deterministic, shown once, and never displaces search results")
func libraryRecommendationDoesNotDuplicateOrOverrideSearch() {
    let a = libraryPresentationModel(id: "A-model", fit: .fits)
    let b = libraryPresentationModel(id: "B-model", fit: .fits)
    let state = ModelCatalogState.available(lastUpdated: .distantPast)
    let collection = ModelLibraryPresentation.collection(from: [b, a], scope: .installed, search: "", catalogState: state)
    #expect(collection.recommendation?.id == a.id)
    #expect(collection.catalogModels.map(\.id) == [b.id])
    #expect(ModelLibraryPresentation.recommendedModel(from: [a, b], catalogState: state)?.id == a.id)
    let search = ModelLibraryPresentation.collection(from: [a, b], scope: .installed, search: "B-model", catalogState: state)
    #expect(search.recommendation == nil)
    #expect(search.catalogModels.map(\.id) == [b.id])
}

@Test("An empty installed collection can suggest a verified catalog download")
func libraryCanRecommendFirstDownload() {
    let candidate = libraryPresentationModel(id: "catalog", fit: .fits, installation: .notInstalled)
    let collection = ModelLibraryPresentation.collection(
        from: [candidate], scope: .installed, search: "", catalogState: .available(lastUpdated: .distantPast)
    )
    #expect(collection.recommendation?.id == candidate.id)
    #expect(collection.catalogModels.isEmpty)
    #expect(!collection.isEmpty)
}

private func libraryPresentationModel(
    id: String,
    fit: ModelFit,
    origin: ModelOrigin = .catalog,
    capabilities: [ModelCapability] = [.textGeneration],
    installation: ModelInstallationState = .installed,
    sizeBytes: Int64 = 1_024,
    displayName: String? = nil
) -> ModelSummary {
    ModelSummary(
        id: id, displayName: displayName ?? id, family: nil, kind: .text, summary: "",
        sizeBytes: sizeBytes, minimumMemoryGB: 8, quantization: nil, maxContextLength: nil,
        capabilities: capabilities, origin: origin, fit: fit, installation: installation, runtime: .cold
    )
}

@Test("Recommendations recognize the production catalog's chat capability")
func productionChatCapabilityCanBeRecommended() {
    let candidate = libraryPresentationModel(id: "catalog/chat", fit: .fits, capabilities: [.init(rawValue: "chat")])
    let state = ModelCatalogState.available(lastUpdated: .distantPast)
    #expect(candidate.supportsChat)
    #expect(ModelLibraryPresentation.recommendedModel(from: [candidate], catalogState: state)?.id == candidate.id)
}

@Test("Recommendations prefer installed fits before download size or alphabetical order")
func modelRecommendationPrefersInstalledFits() {
    let installed = libraryPresentationModel(id: "Z-installed", fit: .fits, sizeBytes: 2_000)
    let hugeDownload = libraryPresentationModel(id: "A-huge", fit: .fits, installation: .notInstalled, sizeBytes: 40_000)
    let smallDownload = libraryPresentationModel(id: "B-small", fit: .fits, installation: .notInstalled, sizeBytes: 500)
    let state = ModelCatalogState.available(lastUpdated: .distantPast)
    for scope in ModelScope.allCases {
        let collection = ModelLibraryPresentation.collection(
            from: [hugeDownload, smallDownload, installed], scope: scope, search: "", catalogState: state
        )
        #expect(collection.recommendation?.id == installed.id)
    }
}

@Test("Recommendations order each installation group by smallest positive footprint")
func modelRecommendationUsesPositiveFootprints() {
    let state = ModelCatalogState.available(lastUpdated: .distantPast)
    for installation in [ModelInstallationState.installed, .notInstalled] {
        let large = libraryPresentationModel(id: "A-large", fit: .fits, installation: installation, sizeBytes: 40_000)
        let small = libraryPresentationModel(id: "Z-small", fit: .fits, installation: installation, sizeBytes: 2_000)
        let zero = libraryPresentationModel(id: "zero", fit: .fits, installation: installation, sizeBytes: 0)
        let negative = libraryPresentationModel(id: "negative", fit: .fits, installation: installation, sizeBytes: -1)
        let unknown = libraryPresentationModel(id: "unknown", fit: .unknown, installation: installation, sizeBytes: 1)
        #expect(ModelLibraryPresentation.recommendedModel(
            from: [large, zero, negative, unknown, small], catalogState: state
        )?.id == small.id)
        #expect(ModelLibraryPresentation.recommendedModel(from: [zero, negative], catalogState: state) == nil)
        let visible = ModelLibraryPresentation.displayedModels(
            from: [zero, negative, unknown], scope: .discover
        )
        #expect(Set(visible.map(\.id)) == Set([zero.id, negative.id, unknown.id]))
    }
}

@Test("Equal recommendation footprints use stable names and then model IDs")
func modelRecommendationHasStableTies() {
    let a = libraryPresentationModel(id: "a", fit: .fits, displayName: "Same name")
    let b = libraryPresentationModel(id: "b", fit: .fits, displayName: "Same name")
    let later = libraryPresentationModel(id: "0", fit: .fits, displayName: "Z name")
    let state = ModelCatalogState.available(lastUpdated: .distantPast)
    for models in [[later, b, a], [a, b, later], [b, later, a]] {
        #expect(ModelLibraryPresentation.recommendedModel(from: models, catalogState: state)?.id == a.id)
    }
}
