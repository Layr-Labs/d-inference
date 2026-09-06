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
