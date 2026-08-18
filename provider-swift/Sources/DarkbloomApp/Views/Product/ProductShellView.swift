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
    let chatFixture: PreviewChatFixture
    let initialDestination: ProductDestination?
    let onSelectDestination: (ProductDestination) -> Void
    let onInitialDestinationApplied: () -> Void

    @SceneStorage("darkbloom.product.destination") private var destinationRawValue = ProductDestination.overview.rawValue
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var showsDiagnostics = false
    @State private var didApplyInitialDestination = false
    @State private var actionConfirmation: ProviderActionConfirmation?

    private var selection: Binding<ProductDestination?> {
        Binding(
            get: { destination },
            set: { destinationRawValue = ($0 ?? .overview).rawValue }
        )
    }

    private var destination: ProductDestination {
        if !didApplyInitialDestination, let initialDestination {
            return initialDestination
        }
        return ProductDestination(rawValue: destinationRawValue) ?? .overview
    }

    var body: some View {
        let primaryAction = providerStore.primaryAction

        NavigationSplitView(columnVisibility: $columnVisibility) {
            ProductSidebarView(
                selection: selection,
                snapshot: providerStore.snapshot
            )
            .navigationSplitViewColumnWidth(min: 178, ideal: 210, max: 248)
        } detail: {
            destinationView
                .toolbar {
                    ProductToolbar(
                        destination: destination,
                        snapshot: providerStore.snapshot,
                        primaryAction: primaryAction,
                        actionIsPending: providerStore.pendingAction != nil,
                        canPerformPrimaryAction: providerStore.canPerform(primaryAction),
                        canRestart: providerStore.canPerform(.restart),
                        onOverview: { select(.overview) },
                        onPerformPrimaryAction: { request(primaryAction) },
                        onRestart: { request(.restart) },
                        onDiagnostics: { showsDiagnostics = true }
                    )
                }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showsDiagnostics) {
            DiagnosticsView(store: diagnosticsStore)
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
        .alert(
            "Darkbloom couldn’t complete that action",
            isPresented: Binding(
                get: { providerStore.failure != nil },
                set: { _ in }
            ),
            actions: {
                if providerStore.retryableFailureAction != nil {
                    Button("Try Again") {
                        Task {
                            await providerStore.retryFailure()
                        }
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
        case .overview:
            ProviderOverviewView(
                identity: identity,
                store: providerStore,
                onOpenChat: { select(.chat) },
                onOpenLocalAPI: { select(.localAPI) },
                onOpenAvailability: { select(.availability) },
                onOpenMachine: { select(.machine) },
                onRequestAction: request
            )
        case .chat:
            PrivateChatView(
                identity: identity,
                fixture: chatFixture
            )
        case .localAPI:
            LocalAPIView(
                store: localAPIStore,
                onOpenChat: { select(.chat) },
                onOpenModels: { select(.models) },
                onOpenDiagnostics: { showsDiagnostics = true }
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
                onOpenDiagnostics: { showsDiagnostics = true }
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
            ModelLibraryView(store: modelLibraryStore)
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
        case .overview, .chat, .contributions, .activity, .models, .machine:
            action.title
        }
    }

    private func perform(_ action: ProviderAction) {
        Task {
            await providerStore.perform(action)
        }
    }

    private func request(_ action: ProviderAction) {
        if let confirmation = ProviderActionConfirmation(
            action: action,
            snapshot: providerStore.snapshot
        ) {
            actionConfirmation = confirmation
        } else {
            perform(action)
        }
    }
}
