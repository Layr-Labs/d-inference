import SwiftUI

struct ModelLibraryView: View {
    let store: ModelLibraryStore

    @State private var scope = ModelScope.installed
    @State private var compatibilityConfirmation: CompatibilityConfirmation?
    @State private var modelToRemove: ModelSummary?

    private var displayedModels: [ModelSummary] {
        ModelLibraryPresentation.displayedModels(from: store.models, scope: scope)
    }

    var body: some View {
        ProductPage {
            ProductPageHeader(
                eyebrow: "Models",
                title: "AI that fits this Mac.",
                subtitle: "Darkbloom can choose a compatible model automatically. Come here only when you want more control."
            ) {
                Picker("Model scope", selection: $scope) {
                    ForEach(ModelScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 210)
            }

            if case let .offline(message, showingCachedResults) = store.catalogState {
                ModelCatalogOfflineBanner(
                    message: message,
                    showingCachedResults: showingCachedResults,
                    onRetry: store.retryCatalog
                )
                .padding(.top, 22)
            }

            if !store.activeTransfers.isEmpty {
                ModelTransferSection(
                    models: store.activeTransfers,
                    onPause: { store.pauseDownload(modelID: $0) },
                    onResume: { store.resumeDownload(modelID: $0) }
                )
                .padding(.top, 24)
            }

            ProductSectionHeader(
                scope == .installed ? "On this Mac" : "Darkbloom catalog",
                detail: scope == .installed
                    ? "\(store.installedModels.count) installed"
                    : catalogDetail
            )
            .padding(.top, 26)

            LazyVStack(spacing: 10) {
                if displayedModels.isEmpty {
                    ModelLibraryEmptyState { scope = .discover }
                } else {
                    ForEach(displayedModels) { model in
                        ModelLibraryRow(
                            model: model,
                            isSelected: store.selectedModelID == model.id,
                            allowsSelection: ModelLibraryPresentation
                                .allowsTransientSelection(isLive: store.isLive),
                            onSelect: { store.selectModel(id: model.id) },
                            onPrimaryAction: { performPrimaryAction(for: model) },
                            onRemove: { modelToRemove = model }
                        )
                    }
                }
            }
            .padding(.top, 10)
        }
        .navigationTitle("Models")
        .confirmationDialog(
            "Download a model larger than this Mac’s recommended limit?",
            isPresented: Binding(
                get: { compatibilityConfirmation != nil },
                set: { if !$0 { compatibilityConfirmation = nil } }
            )
        ) {
            if let confirmation = compatibilityConfirmation {
                Button("Download anyway") {
                    store.beginDownload(modelID: confirmation.modelID, allowingIncompatibleModel: true)
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

    private var catalogDetail: String {
        ModelLibraryPresentation.catalogDetail(for: store.catalogState)
    }

    private var activeTransferSignature: String {
        ModelLibraryPresentation.activeTransferSignature(for: store.activeTransfers)
    }

    private var actionErrorMessage: String? {
        ModelLibraryPresentation.actionErrorMessage(for: store.lastActionResult)
    }

    private func performPrimaryAction(for model: ModelSummary) {
        switch model.installation {
        case .notInstalled:
            let result = store.beginDownload(modelID: model.id)
            if case let .requiresCompatibilityConfirmation(required, available) = result {
                compatibilityConfirmation = CompatibilityConfirmation(
                    modelID: model.id,
                    requiredMemoryGB: required,
                    availableMemoryGB: available
                )
            }
        case .failed(let failure):
            if failure.isResumable {
                store.resumeDownload(modelID: model.id)
            } else {
                store.beginDownload(modelID: model.id)
            }
        case .paused:
            store.resumeDownload(modelID: model.id)
        case .downloading:
            store.pauseDownload(modelID: model.id)
        case .verifying:
            break
        case .installed:
            store.selectModel(id: model.id)
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
