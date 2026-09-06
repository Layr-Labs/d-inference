import SwiftUI

struct PrivateChatView: View {
    let identity: MachineIdentity
    private let onOpenLocalAPI: (() -> Void)?
    private let onOpenModels: (() -> Void)?
    private let localAPIStore: LocalAPIStore?
    private let modelLibraryStore: ModelLibraryStore?
    private let providerSnapshot: ProviderSnapshot?
    private let onOpenDiagnostics: (() -> Void)?
    private let onOpenProviderControls: (() -> Void)?
    private let onProcessChange: @MainActor () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: ChatStore
    @State private var responseTask: Task<Void, Never>?
    @State private var connectionTask: Task<Void, Never>?
    @State private var composerIsFocused = false

    /// Preferred shell integration: keep the store at shell/app scope so
    /// transcript, draft and in-memory history survive destination changes.
    init(
        identity: MachineIdentity,
        store: ChatStore,
        onOpenLocalAPI: (() -> Void)? = nil,
        onOpenModels: (() -> Void)? = nil,
        localAPIStore: LocalAPIStore? = nil,
        modelLibraryStore: ModelLibraryStore? = nil,
        providerSnapshot: ProviderSnapshot? = nil,
        onOpenDiagnostics: (() -> Void)? = nil,
        onOpenProviderControls: (() -> Void)? = nil,
        onProcessChange: @escaping @MainActor () -> Void = {}
    ) {
        self.identity = identity
        self.onOpenLocalAPI = onOpenLocalAPI
        self.onOpenModels = onOpenModels
        self.localAPIStore = localAPIStore
        self.modelLibraryStore = modelLibraryStore
        self.providerSnapshot = providerSnapshot
        self.onOpenDiagnostics = onOpenDiagnostics
        self.onOpenProviderControls = onOpenProviderControls
        self.onProcessChange = onProcessChange
        _store = State(initialValue: store)
    }

    /// Compatibility initializer for existing product/preview callers.
    init(
        identity: MachineIdentity,
        fixture: PreviewChatFixture = .empty,
        isPreview: Bool,
        onOpenLocalAPI: (() -> Void)? = nil,
        onOpenModels: (() -> Void)? = nil,
        localAPIStore: LocalAPIStore? = nil,
        modelLibraryStore: ModelLibraryStore? = nil,
        providerSnapshot: ProviderSnapshot? = nil,
        onOpenDiagnostics: (() -> Void)? = nil,
        onOpenProviderControls: (() -> Void)? = nil,
        onProcessChange: @escaping @MainActor () -> Void = {}
    ) {
        self.init(
            identity: identity,
            store: isPreview ? ChatStore(fixture: fixture) : ChatStore(live: LiveChatConfiguration()),
            onOpenLocalAPI: onOpenLocalAPI,
            onOpenModels: onOpenModels,
            localAPIStore: localAPIStore,
            modelLibraryStore: modelLibraryStore,
            providerSnapshot: providerSnapshot,
            onOpenDiagnostics: onOpenDiagnostics,
            onOpenProviderControls: onOpenProviderControls,
            onProcessChange: onProcessChange
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 760
            VStack(spacing: 0) {
                sessionHeader
                    .padding(.horizontal, compact ? 24 : 40)
                    .padding(.vertical, 16)
                    .fixedSize(horizontal: false, vertical: true)

                if store.hasConversation {
                    ChatConversationView(
                        messages: store.messages,
                        isResponding: store.isResponding,
                        isLive: store.isLive
                    )
                    .id(store.conversationID)
                    .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)

                    // Expanded diagnostics scroll independently at the minimum
                    // window size, leaving the editor and Stop within reach.
                    ViewThatFits(in: .vertical) {
                        recoveryContent.fixedSize(horizontal: false, vertical: true)
                        ScrollView { recoveryContent }
                            .frame(height: 116)
                    }
                    .frame(maxHeight: 116, alignment: .top)
                    .padding(.horizontal, compact ? 24 : 40)

                    composer(prominent: false)
                        .padding(.horizontal, compact ? 24 : 40)
                        .padding(.top, 12)
                        .padding(.bottom, 20)
                } else {
                    ScrollView {
                        ChatEmptyState(compact: compact, onSelectSuggestion: useSuggestion) {
                            composer(prominent: true)
                            localStartControls
                            failureNotice
                        }
                        .padding(.horizontal, compact ? 24 : 40)
                        .padding(.top, geometry.size.height < 540 ? 12 : (compact ? 16 : 44))
                        .padding(.bottom, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(StudioPalette.canvas)
        .foregroundStyle(StudioPalette.ink)
        .tint(StudioPalette.accent)
        .modifier(ChatLocalStartObservation(
            store: localAPIStore, library: modelLibraryStore,
            chat: store, onRefreshConnection: checkConnection
        ))
        .task {
            composerIsFocused = true
            await store.refreshConnection()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { checkConnection() }
        }
        .onDisappear {
            connectionTask?.cancel()
            stopResponse()
        }
        .accessibilityElement(children: .contain)
    }

    private var sessionHeader: some View {
        @Bindable var chat = store
        return ChatSessionHeader(
            isLive: store.isLive,
            connection: store.connection,
            availableModelIDs: store.availableModelIDs,
            selectedModelID: $chat.selectedModelID,
            isResponding: store.isResponding,
            history: store.history,
            canStartNewChat: store.canStartNewChat,
            onNewChat: resetConversation,
            onRestore: restoreConversation,
            onRefresh: checkConnection
        )
    }

    private var recoveryContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            failureNotice
            localStartControls
        }
    }

    private var hasInlineStart: Bool {
        store.isLive && localAPIStore != nil && modelLibraryStore != nil
    }

    @ViewBuilder
    private var localStartControls: some View {
        if store.isLive, let localAPIStore, let modelLibraryStore {
            ChatLocalStartView(
                store: localAPIStore,
                library: modelLibraryStore,
                chat: store,
                providerSnapshot: providerSnapshot,
                onOpenModels: onOpenModels,
                onOpenDiagnostics: onOpenDiagnostics ?? onOpenLocalAPI,
                onOpenProviderControls: onOpenProviderControls,
                onProcessChange: onProcessChange,
                onRefreshConnection: checkConnection
            )
            .frame(maxWidth: 840, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var failureNotice: some View {
        if let issue = displayedFailure {
            let retry: (() -> Void)? = store.canRetry ? { retryFailedResponse() } : nil
            let canCheck = store.isLive && !store.isResponding && store.connection != .checking
            let check: (() -> Void)? = canCheck ? { checkConnection() } : nil
            let dismiss: (() -> Void)? = store.failure != nil ? { store.clearFailure() } : nil
            ChatFailureNotice(
                failure: issue,
                onRetry: retry,
                onCheckConnection: check,
                onOpenLocalAPI: hasInlineStart ? onOpenDiagnostics : onOpenLocalAPI,
                onOpenModels: onOpenModels,
                onDismiss: dismiss,
                hasInlineStart: hasInlineStart
            )
            .frame(maxWidth: 840, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func composer(prominent: Bool) -> some View {
        @Bindable var chat = store
        return ChatComposer(
            draft: $chat.draft,
            route: $chat.route,
            isFocused: $composerIsFocused,
            conversationID: store.conversationID,
            isResponding: store.isResponding,
            isLive: store.isLive,
            canSend: store.canSend,
            availableRoutes: store.isLive ? [.thisMac] : ChatRoute.allCases,
            isProminent: prominent,
            onSubmit: submit,
            onStop: stopResponse
        )
        .frame(maxWidth: 840)
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var displayedFailure: ChatFailure? {
        if let failure = store.failure { return failure }
        if case .unavailable(let failure) = store.connection {
            // Expected setup states are explained beside the inline Start action.
            // A failed turn still takes precedence and retains its retry action.
            if hasInlineStart && (failure == .noDiscovery || failure == .untrustedDiscovery || failure == .noModels) {
                return nil
            }
            return failure
        }
        return store.modelSelectionFailure
    }

    private func submit() {
        guard store.canSend, let prompt = store.beginResponse(to: store.draft) else { return }
        store.draft = ""
        startResponse(prompt)
    }

    private func useSuggestion(_ prompt: String) {
        // Suggestions never overwrite work in progress or immediately send.
        if store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            store.draft = prompt
        } else {
            store.draft += "\n\n" + prompt
        }
        composerIsFocused = true
    }

    private func retryFailedResponse() {
        guard let prompt = store.retryLastFailedResponse() else { return }
        startResponse(prompt)
    }

    private func startResponse(_ prompt: String) {
        responseTask?.cancel()
        responseTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            if store.isLive {
                await store.respondLive(to: prompt)
            } else {
                if !reduceMotion { try? await Task.sleep(for: .milliseconds(620)) }
                guard !Task.isCancelled else { return }
                store.completeResponse(to: prompt)
            }
            guard !Task.isCancelled else { return }
            responseTask = nil
        }
        composerIsFocused = true
    }

    private func checkConnection() {
        connectionTask?.cancel()
        connectionTask = Task { await store.refreshConnection() }
    }

    private func stopResponse() {
        responseTask?.cancel()
        responseTask = nil
        store.stopResponse()
    }

    private func resetConversation() {
        stopResponse()
        store.reset()
        composerIsFocused = true
    }

    private func restoreConversation(_ id: UUID) {
        stopResponse()
        store.restoreConversation(id)
        composerIsFocused = true
    }
}
