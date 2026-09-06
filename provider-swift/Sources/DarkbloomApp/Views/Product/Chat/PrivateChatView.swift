import SwiftUI

struct PrivateChatView: View {
    let identity: MachineIdentity
    private let onOpenLocalAPI: (() -> Void)?
    private let onOpenModels: (() -> Void)?

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
        onOpenModels: (() -> Void)? = nil
    ) {
        self.identity = identity
        self.onOpenLocalAPI = onOpenLocalAPI
        self.onOpenModels = onOpenModels
        _store = State(initialValue: store)
    }

    /// Compatibility initializer for existing product/preview callers.
    init(
        identity: MachineIdentity,
        fixture: PreviewChatFixture = .empty,
        isPreview: Bool,
        onOpenLocalAPI: (() -> Void)? = nil,
        onOpenModels: (() -> Void)? = nil
    ) {
        self.init(
            identity: identity,
            store: isPreview ? ChatStore(fixture: fixture) : ChatStore(live: LiveChatConfiguration()),
            onOpenLocalAPI: onOpenLocalAPI,
            onOpenModels: onOpenModels
        )
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                sessionHeader
                    .fixedSize(horizontal: false, vertical: true)
                conversationContent
                    .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                failureNotice
                composer
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(ProductPalette.pageBackground)
        .navigationTitle("Chat")
        .toolbar(id: "darkbloom.chat.actions") {
            ChatToolbar(canStartNewChat: store.canStartNewChat, onNewChat: resetConversation)
        }
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
            onRestore: restoreConversation,
            onRefresh: checkConnection
        )
    }

    @ViewBuilder
    private var conversationContent: some View {
        if store.hasConversation {
            ChatConversationView(
                messages: store.messages,
                isResponding: store.isResponding,
                isLive: store.isLive
            )
            .id(store.conversationID)
        } else {
            ScrollView {
                ChatEmptyState(
                    identity: identity,
                    route: store.route,
                    detailOverride: store.isLive
                        ? "Ask questions, work through code, or try an idea with a model on \(identity.displayName). Messages go directly to your local endpoint."
                        : nil,
                    onSelectSuggestion: useSuggestion
                )
            }
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
                onOpenLocalAPI: onOpenLocalAPI,
                onOpenModels: onOpenModels,
                onDismiss: dismiss
            )
        }
    }

    private var composer: some View {
        @Bindable var chat = store
        return VStack(spacing: 0) {
            Divider()
            ChatComposer(
                draft: $chat.draft,
                route: $chat.route,
                isFocused: $composerIsFocused,
                conversationID: store.conversationID,
                isResponding: store.isResponding,
                isLive: store.isLive,
                canSend: store.canSend,
                availableRoutes: store.isLive ? [.thisMac] : ChatRoute.allCases,
                onSubmit: submit,
                onStop: stopResponse
            )
        }
        .background(.bar)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var displayedFailure: ChatFailure? {
        if let failure = store.failure { return failure }
        if case .unavailable(let failure) = store.connection { return failure }
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
