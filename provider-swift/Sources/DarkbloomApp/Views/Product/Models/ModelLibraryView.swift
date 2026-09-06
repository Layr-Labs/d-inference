import SwiftUI

struct ModelLibraryView: View {
    let store: ModelLibraryStore
    var onUseModel: ((String) -> Void)? = nil

    @State private var scope = ModelScope.installed
    @State private var searchText = ""
    @State private var compatibilityConfirmation: CompatibilityConfirmation?
    @State private var modelToRemove: ModelSummary?

    private var collection: ModelLibraryCollection {
        ModelLibraryPresentation.collection(
            from: store.models,
            scope: scope,
            search: searchText,
            catalogState: store.catalogState
        )
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isRefreshing: Bool {
        if case .loading = store.catalogState { return true }
        return false
    }

    var body: some View {
        let collection = self.collection

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Model library")
                        .font(DarkbloomTheme.chivo(34, weight: .medium))
                        .tracking(-1)
                        .accessibilityAddTraits(.isHeader)
                    Text("Choose a model for local AI. Manage what’s on this Mac.")
                        .font(.system(size: 13))
                        .foregroundStyle(StudioPalette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ModelLibraryControls(
                    scope: $scope,
                    searchText: $searchText,
                    isRefreshing: isRefreshing,
                    onRefresh: store.retryCatalog
                )

                if case let .offline(message, showingCachedResults) = store.catalogState {
                    ModelCatalogOfflineBanner(
                        message: message,
                        showingCachedResults: showingCachedResults,
                        onRetry: store.retryCatalog
                    )
                }

                if !collection.transfers.isEmpty {
                    ModelTransferSection(
                        models: collection.transfers,
                        onPause: { store.pauseDownload(modelID: $0) },
                        onResume: { modelID in
                            Task { await store.resumeDownload(modelID: modelID) }
                        }
                    )
                }

                if collection.isEmpty {
                    if isRefreshing {
                        ProgressView("Finding models…")
                            .frame(maxWidth: .infinity, minHeight: 150)
                    } else {
                        ModelLibraryEmptyState(scope: scope, searchText: searchText) {
                            if isSearching {
                                searchText = ""
                            } else if scope == .installed {
                                scope = .discover
                            } else {
                                store.retryCatalog()
                            }
                        }
                    }
                } else {
                    ModelLibraryCollectionView(
                        collection: collection,
                        scope: scope,
                        isSearching: isSearching,
                        selectedModelID: store.selectedModelID,
                        allowsSelection: ModelLibraryPresentation.allowsTransientSelection(isLive: store.isLive),
                        offersLocalStart: onUseModel != nil,
                        onSelect: { store.selectModel(id: $0.id) },
                        onPrimaryAction: { model in
                            Task { await performPrimaryAction(for: model) }
                        },
                        onRemove: { modelToRemove = $0 }
                    )
                }
            }
            .frame(maxWidth: 960, alignment: .leading)
            .padding(.horizontal, 26)
            .padding(.top, 24)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .foregroundStyle(StudioPalette.ink)
        .background(StudioPalette.canvas)
        .tint(StudioPalette.accent)
        .confirmationDialog(
            "Download a model larger than this Mac’s recommended limit?",
            isPresented: Binding(
                get: { compatibilityConfirmation != nil },
                set: { if !$0 { compatibilityConfirmation = nil } }
            )
        ) {
            if let confirmation = compatibilityConfirmation {
                Button("Download anyway") {
                    Task {
                        await store.beginDownload(
                            modelID: confirmation.modelID,
                            allowingIncompatibleModel: true
                        )
                    }
                    compatibilityConfirmation = nil
                }
                Button("Cancel", role: .cancel) {
                    compatibilityConfirmation = nil
                }
            }
        } message: {
            if let confirmation = compatibilityConfirmation {
                Text("This model recommends \(confirmation.requiredMemoryGB) GB. This Mac has \(confirmation.availableMemoryGB) GB available for it, so loading may fail.")
            }
        }
        .confirmationDialog(
            "Remove this model?",
            isPresented: Binding(
                get: { modelToRemove != nil },
                set: { if !$0 { modelToRemove = nil } }
            )
        ) {
            if let selectedModel = modelToRemove {
                Button("Remove \(selectedModel.displayName)", role: .destructive) {
                    store.removeModel(modelID: selectedModel.id)
                    modelToRemove = nil
                }
                Button("Cancel", role: .cancel) {
                    modelToRemove = nil
                }
            }
        } message: {
            if let modelToRemove {
                Text(
                    modelToRemove.isAvailableFromCatalog
                        ? "You can download it again from the Darkbloom catalog."
                        : "This model is not in the active catalog. Removing it may be irreversible."
                )
            }
        }
        .alert(
            "That model action isn’t available",
            isPresented: Binding(
                get: { actionErrorMessage != nil },
                set: { if !$0 { store.clearLastActionResult() } }
            )
        ) {
            Button("OK") { store.clearLastActionResult() }
        } message: {
            Text(actionErrorMessage ?? "Try again.")
        }
        .task(id: activeTransferSignature) {
            await advanceModelTransfers()
        }
        .task {
            // Live mode: kick the first real catalog/local fetch (no-op for
            // fixture previews and safe to re-run on screen re-entry).
            await store.start()
        }
    }

    private var activeTransferSignature: String {
        ModelLibraryPresentation.activeTransferSignature(for: store.activeTransfers)
    }

    private var actionErrorMessage: String? {
        ModelLibraryPresentation.actionErrorMessage(for: store.lastActionResult)
    }

    private func performPrimaryAction(for model: ModelSummary) async {
        switch model.installation {
        case .notInstalled:
            await requestDownload(for: model)
        case .failed(let failure):
            if failure.isResumable {
                await store.resumeDownload(modelID: model.id)
            } else {
                await requestDownload(for: model)
            }
        case .paused:
            await store.resumeDownload(modelID: model.id)
        case .downloading:
            store.pauseDownload(modelID: model.id)
        case .verifying:
            break
        case .installed:
            store.selectModel(id: model.id)
            onUseModel?(model.id)
        }
    }

    private func requestDownload(for model: ModelSummary) async {
        let result = await store.beginDownload(modelID: model.id)
        if case let .requiresCompatibilityConfirmation(required, available) = result {
            compatibilityConfirmation = CompatibilityConfirmation(
                modelID: model.id,
                requiredMemoryGB: required,
                availableMemoryGB: available
            )
        }
    }

    private func advanceModelTransfers() async {
        // Live mode: transfers are driven by the real CLI download stream,
        // not this fixture simulation loop.
        guard !store.isLive else { return }
        while !Task.isCancelled {
            let models = store.activeTransfers.filter { model in
                switch model.installation {
                case .downloading, .verifying: true
                case .paused, .notInstalled, .installed, .failed: false
                }
            }
            guard !models.isEmpty else { return }

            do {
                try await Task.sleep(for: .milliseconds(450))
            } catch {
                return
            }

            for model in models {
                guard !Task.isCancelled else { return }
                switch model.installation {
                case .downloading:
                    _ = store.advanceDownload(modelID: model.id)
                case .verifying:
                    _ = store.finishVerification(modelID: model.id, succeeds: true)
                case .paused, .notInstalled, .installed, .failed:
                    break
                }
            }
        }
    }
}
