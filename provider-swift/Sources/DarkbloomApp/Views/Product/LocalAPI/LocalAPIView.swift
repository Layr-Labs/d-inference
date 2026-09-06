import AppKit
import SwiftUI

struct LocalAPIView: View {
    let store: LocalAPIStore
    let onOpenChat: () -> Void
    let onOpenModels: () -> Void
    let onOpenDiagnostics: () -> Void
    let models: [ModelSummary]
    let modelsAreLive: Bool
    let modelCatalogState: ModelCatalogState
    let selectedModelID: String?
    let onSelectModel: (String) -> Void
    let providerSnapshot: ProviderSnapshot?
    let onRefreshModels: () async -> Void
    let onOpenProviderControls: () -> Void
    let onProcessChange: @MainActor () -> Void

    init(
        store: LocalAPIStore,
        onOpenChat: @escaping () -> Void,
        onOpenModels: @escaping () -> Void,
        onOpenDiagnostics: @escaping () -> Void,
        models: [ModelSummary] = [],
        modelsAreLive: Bool = false,
        modelCatalogState: ModelCatalogState = .loading,
        selectedModelID: String? = nil,
        providerSnapshot: ProviderSnapshot? = nil,
        onRefreshModels: @escaping () async -> Void = {},
        onSelectModel: @escaping (String) -> Void = { _ in },
        onOpenProviderControls: @escaping () -> Void = {},
        onProcessChange: @escaping @MainActor () -> Void = {}
    ) {
        self.store = store
        self.onOpenChat = onOpenChat
        self.onOpenModels = onOpenModels
        self.onOpenDiagnostics = onOpenDiagnostics
        self.models = models
        self.modelsAreLive = modelsAreLive
        self.modelCatalogState = modelCatalogState
        self.selectedModelID = selectedModelID
        self.onSelectModel = onSelectModel
        self.providerSnapshot = providerSnapshot
        self.onRefreshModels = onRefreshModels
        self.onOpenProviderControls = onOpenProviderControls
        self.onProcessChange = onProcessChange
    }

    var body: some View {
        ProductPage {
            VStack(alignment: .leading, spacing: 0) {
                header

                LocalAPIStartControls(
                    store: store, models: models, modelsAreLive: modelsAreLive,
                    catalogState: modelCatalogState, providerSnapshot: providerSnapshot,
                    onOpenModels: onOpenModels, onOpenChat: onOpenChat,
                    onOpenProviderControls: onOpenProviderControls,
                    onOpenDiagnostics: onOpenDiagnostics, onSelectModel: onSelectModel,
                    onProcessChange: onProcessChange
                )
                .padding(.top, 26)
                .padding(.bottom, 22)

                stateContent

                LocalAPIStartCommandsView(store: store, copiedItem: store.lastCopiedItem, onCopy: copy)
            }
            .foregroundStyle(StudioPalette.ink)
            .tint(StudioPalette.accent)
        }
        .navigationTitle("Local API")
        // Live stores poll ~/.darkbloom/local.json + probe the endpoint while
        // this surface is visible; fixture stores no-op so previews stay frozen.
        .task { store.startMonitoring() }
        .task { await onRefreshModels() }
        .onChange(of: models, initial: true) { _, models in
            store.syncLocalModelSelection(preferredID: selectedModelID, models: models)
        }
        .onChange(of: selectedModelID, initial: true) { _, selectedID in
            store.syncLocalModelSelection(preferredID: selectedID, models: models)
        }
        .task(id: store.lastCopiedItem) {
            guard store.lastCopiedItem != nil else { return }
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.16)) {
                store.clearCopyConfirmation()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            store.hideAPIKey()
        }
        .onDisappear {
            store.stopMonitoring()
            store.hideAPIKey()
            store.clearCopyConfirmation()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Local API")
                    .font(DarkbloomTheme.chivo(32, weight: .medium))
                    .tracking(-0.8)
                    .accessibilityAddTraits(.isHeader)
                Text(store.isLive
                    ? "Connect your tools to a model on this Mac."
                    : "Explore a sample connection for your tools.")
                    .font(.system(size: 13))
                    .foregroundStyle(StudioPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch store.state {
        case .running(let endpoint):
            endpointContent(endpoint)

        case .starting(let message):
            LocalAPIStateView(
                kind: .starting,
                message: message,
                isLive: store.isLive,
                onRetry: {},
                onOpenDiagnostics: onOpenDiagnostics
            )

        case .stopped(let message):
            LocalAPIStateView(
                kind: .stopped,
                message: message,
                isLive: store.isLive,
                onRetry: {},
                onOpenDiagnostics: onOpenDiagnostics
            )

        case .unavailable(let message):
            LocalAPIStateView(
                kind: .unavailable,
                message: message,
                isLive: store.isLive,
                onRetry: store.retryPreviewDiscovery,
                onOpenDiagnostics: onOpenDiagnostics
            )
        }
    }

    @ViewBuilder
    private func endpointContent(_ endpoint: LocalAPIEndpointSnapshot) -> some View {
        switch endpoint.health {
        case .checking:
            LocalAPIStateView(
                kind: .starting,
                message: "A provider process was found. Checking its HTTP endpoint before showing connection details.",
                isLive: store.isLive,
                onRetry: {},
                onOpenDiagnostics: onOpenDiagnostics
            )

        case .unreachable:
            LocalAPIStateView(
                kind: .unavailable,
                message: "The provider process is running, but its HTTP endpoint did not respond. Connection details stay hidden until it responds.",
                isLive: store.isLive,
                onRetry: store.retryPreviewHealth,
                onOpenDiagnostics: onOpenDiagnostics
            )

        case .reachable:
            reachableContent(endpoint)
        }
    }

    @ViewBuilder
    private func reachableContent(_ endpoint: LocalAPIEndpointSnapshot) -> some View {
        LocalAPIConnectionSurface(
            endpoint: endpoint,
            isLive: store.isLive,
            isAPIKeyRevealed: store.isAPIKeyRevealed,
            copiedItem: store.lastCopiedItem,
            onRevealAPIKey: store.setAPIKeyRevealed,
            onCopy: copy,
            onOpenModels: onOpenModels
        )

        if endpoint.bindScope != .thisMac {
            networkExposureWarning(endpoint)
                .padding(.top, 14)
        }

        LocalAPICodeExampleView(
            store: store,
            endpoint: endpoint,
            onCopy: copy,
            onOpenModels: onOpenModels,
            onRetryCatalog: store.retryPreviewModelCatalog,
            onOpenDiagnostics: onOpenDiagnostics
        )

        LocalAPIExplanationView(endpoint: endpoint)
    }

    private func networkExposureWarning(_ endpoint: LocalAPIEndpointSnapshot) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(ProductPalette.warning)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(store.isLive ? "Network access is enabled" : "Sample network access is enabled")
                    .font(.system(size: 12, weight: .semibold))
                Text(LocalAPIPresentation.accessDetail(endpoint.bindScope))
                    .font(.system(size: 12))
                    .foregroundStyle(StudioPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)

                if endpoint.bindScope == .allInterfaces {
                    Text(endpoint.requiresAuthentication
                        ? "The copied URL is for this Mac. Other devices need its trusted network address and API key."
                        : "The copied URL is for this Mac. Other devices need its network address; authentication is disabled.")
                        .font(.system(size: 12))
                        .foregroundStyle(StudioPalette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func copy(_ item: LocalAPICopyItem) {
        guard let value = store.text(for: item) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        withAnimation(.easeOut(duration: 0.16)) {
            store.markCopied(item)
        }
        AccessibilityNotification.Announcement(item.confirmation).post()
    }
}
