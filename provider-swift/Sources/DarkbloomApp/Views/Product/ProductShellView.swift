import SwiftUI

struct ProductShellView: View {
    let identity: MachineIdentity
    let providerStore: ProviderStore
    let modelLibraryStore: ModelLibraryStore
    let diagnosticsStore: DiagnosticsStore
    let contributionsStore: ContributionsStore
    let localAPIStore: LocalAPIStore
    let myMacsStore: MyMacsStore
    let availabilityStore: AvailabilityStore
    let isPreview: Bool
    let chatStore: ChatStore
    let needsSetup: Bool
    let onContinueSetup: () -> Void
    let initialDestination: ProductDestination?
    let navigationRequest: ProductDestination?
    let onSelectDestination: (ProductDestination) -> Void
    let onInitialDestinationApplied: () -> Void

    @SceneStorage("darkbloom.product.destination") private var destinationRawValue = ProductDestination.overview.rawValue
    @State private var showsDiagnostics = false
    @State private var didApplyInitialDestination = false
    @State private var actionConfirmation: ProviderActionConfirmation?
    @State private var showsLocalSessionConflict = false

    private var destination: ProductDestination {
        if !didApplyInitialDestination, let initialDestination {
            return initialDestination
        }
        return ProductDestination(rawValue: destinationRawValue) ?? .overview
    }

    var body: some View {
        let primaryAction = providerStore.primaryAction

        VStack(spacing: 0) {
            StudioNavigation(
                destination: destination,
                needsSetup: needsSetup,
                onSelect: select,
                onContinueSetup: onContinueSetup,
                onDiagnostics: { showsDiagnostics = true }
            )
            if isPreview { UIPreviewNotice() }
            destinationView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(StudioPalette.canvas)
        .foregroundStyle(StudioPalette.ink)
        .tint(StudioPalette.accent)
        .sheet(isPresented: $showsDiagnostics) {
            DiagnosticsView(store: diagnosticsStore)
        }
        .alert("Your local session is still running", isPresented: $showsLocalSessionConflict) {
            Button("Open Studio") { select(.overview) }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("End the session in Studio before starting network sharing. Your conversation and draft will stay in this app.")
        }
        .focusedSceneValue(
            \.providerActions,
            FocusedProviderActions(
                primaryTitle: focusedPrimaryTitle(primaryAction),
                canPerformPrimary: !destination.hidesProviderLifecycleControls
                    && providerStore.canPerform(primaryAction),
                performPrimary: { request(primaryAction) },
                restartTitle: destination == .myMacs
                    ? "Restart This Mac’s Network Provider"
                    : "Restart Network Provider",
                canRestart: !destination.hidesProviderLifecycleControls
                    && providerStore.canPerform(.restart),
                restart: { request(.restart) },
                showDiagnostics: { showsDiagnostics = true }
            )
        )
        .task {
            if !didApplyInitialDestination, let initialDestination {
                await Task.yield()
                destinationRawValue = initialDestination.rawValue
                didApplyInitialDestination = true
                onInitialDestinationApplied()
            }
            providerStore.startMonitoring()
        }
        .onChange(of: destinationRawValue) { _, newValue in
            guard let destination = ProductDestination(rawValue: newValue) else { return }
            onSelectDestination(destination)
        }
        .onChange(of: navigationRequest) { _, requested in
            guard let requested else { return }
            destinationRawValue = requested.rawValue
            didApplyInitialDestination = true
            onInitialDestinationApplied()
        }
        .alert(
            "Darkbloom couldn’t complete that action",
            isPresented: Binding(
                get: { providerStore.failure != nil },
                set: { _ in }
            ),
            actions: {
                if let action = providerStore.retryableFailureAction {
                    Button("Try Again") {
                        providerStore.dismissFailure()
                        request(action)
                    }
                }

                Button(
                    providerStore.retryableFailureAction == nil ? "OK" : "Dismiss",
                    role: .cancel
                ) {
                    providerStore.dismissFailure()
                }
            },
            message: {
                Text(providerStore.failure?.message ?? "Try again.")
            }
        )
        .confirmationDialog(
            actionConfirmation?.title ?? "Continue?",
            isPresented: Binding(
                get: { actionConfirmation != nil },
                set: { if !$0 { actionConfirmation = nil } }
            )
        ) {
            if let confirmation = actionConfirmation {
                Button(confirmation.buttonTitle, role: .destructive) {
                    actionConfirmation = nil
                    perform(confirmation.action)
                }
                Button("Cancel", role: .cancel) {
                    actionConfirmation = nil
                }
            }
        } message: {
            Text(actionConfirmation?.message ?? "")
        }
    }

    @ViewBuilder
    private var destinationView: some View {
        switch destination {
        case .networkOverview:
            ProviderOverviewView(
                identity: identity,
                store: providerStore,
                needsSetup: needsSetup,
                localSessionIsActive: localAPIStore.localStart.hasActiveSession,
                onContinueSetup: onContinueSetup,
                onOpenChat: { select(.chat) },
                onOpenAvailability: { select(.availability) },
                onOpenMachine: { select(.machine) },
                onRequestAction: request
            )
        case .overview, .chat:
            PrivateChatView(
                identity: identity,
                store: chatStore,
                onOpenLocalAPI: { select(.localAPI) },
                onOpenModels: { select(.models) },
                localAPIStore: localAPIStore,
                modelLibraryStore: modelLibraryStore,
                providerSnapshot: providerStore.snapshot,
                onOpenDiagnostics: { showsDiagnostics = true },
                onOpenProviderControls: { select(.networkOverview) },
                onProcessChange: { Task { await providerStore.refresh() } }
            )
        case .localAPI:
            LocalAPIView(
                store: localAPIStore,
                onOpenChat: { select(.chat) },
                onOpenModels: { select(.models) },
                onOpenDiagnostics: { showsDiagnostics = true },
                models: modelLibraryStore.models,
                modelsAreLive: modelLibraryStore.isLive,
                modelCatalogState: modelLibraryStore.catalogState,
                selectedModelID: modelLibraryStore.selectedModelID,
                providerSnapshot: providerStore.snapshot,
                onRefreshModels: { await modelLibraryStore.refresh() },
                onSelectModel: { modelLibraryStore.selectModel(id: $0) },
                onOpenProviderControls: { select(.networkOverview) },
                onProcessChange: { Task { await providerStore.refresh() } }
            )
        case .myMacs:
            MyMacsView(
                store: myMacsStore,
                currentMachine: identity,
                onOpenContributions: { select(.contributions) },
                onOpenHardware: { select(.machine) },
                onOpenActivity: { select(.activity) },
                onOpenModels: { select(.models) },
                onRunSystemCheck: { showsDiagnostics = true }
            )
        case .contributions:
            ContributionsView(
                store: contributionsStore,
                onReviewAvailability: { select(.availability) },
                onOpenDiagnostics: { showsDiagnostics = true },
                identity: identity
            )
        case .availability:
            AvailabilityView(
                store: availabilityStore,
                providerSnapshot: providerStore.snapshot,
                onRequestProviderAction: request,
                onRunSystemCheck: { showsDiagnostics = true }
            )
        case .activity:
            ProviderActivityView(snapshot: providerStore.snapshot)
        case .models:
            ModelLibraryView(store: modelLibraryStore) { modelID in
                modelLibraryStore.selectModel(id: modelID)
                ChatModelHandoff.select(modelID, in: chatStore)
                select(.chat)
            }
        case .machine:
            MachineOverviewView(
                identity: identity,
                trust: providerStore.snapshot.trust,
                onRunDiagnostics: { showsDiagnostics = true }
            )
        }
    }

    private func select(_ destination: ProductDestination) {
        withAnimation(.easeOut(duration: 0.2)) {
            destinationRawValue = destination.rawValue
        }
    }

    private func focusedPrimaryTitle(_ action: ProviderAction) -> String {
        switch destination {
        case .localAPI:
            "\(action.title) Network Provider"
        case .myMacs, .availability:
            "\(action.title) This Mac"
        case .overview, .chat, .networkOverview, .contributions, .activity, .models, .machine:
            action.title
        }
    }

    private func perform(_ action: ProviderAction) {
        Task {
            // Confirmation and task scheduling can outlive the state checked
            // by request(_:). Recheck before any provider process mutation.
            guard mayBegin(action), providerStore.canPerform(action) else { return }
            await providerStore.perform(action)
        }
    }

    private func request(_ action: ProviderAction) {
        guard mayBegin(action), providerStore.canPerform(action) else { return }
        if let confirmation = ProviderActionConfirmation(
            action: action,
            snapshot: providerStore.snapshot
        ) {
            actionConfirmation = confirmation
        } else {
            perform(action)
        }
    }

    private func mayBegin(_ action: ProviderAction) -> Bool {
        if localAPIStore.localStart.hasActiveSession && (action == .start || action == .restart) {
            showsLocalSessionConflict = true
            return false
        }
        if needsSetup && (action == .start || action == .restart) {
            onContinueSetup()
            return false
        }
        return true
    }
}
