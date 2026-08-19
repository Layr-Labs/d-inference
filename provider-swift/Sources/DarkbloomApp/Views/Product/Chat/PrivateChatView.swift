import SwiftUI

struct PrivateChatView: View {
    let identity: MachineIdentity

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var store: PreviewChatStore
    @State private var draft = ""
    @State private var responseTask: Task<Void, Never>?
    @FocusState private var composerIsFocused: Bool

    init(
        identity: MachineIdentity,
        fixture: PreviewChatFixture = .empty
    ) {
        self.identity = identity
        // Preview captures (DEBUG env config) stay fixture-driven and fully
        // deterministic. Real launches chat against the actual local endpoint
        // from ~/.darkbloom/local.json through the live store.
        if ProductPreviewConfiguration.current != nil {
            _store = State(initialValue: PreviewChatStore(fixture: fixture))
        } else {
            _store = State(initialValue: PreviewChatStore(live: LiveChatConfiguration()))
        }
    }

    var body: some View {
        GeometryReader { geometry in
            chatSurface
                .frame(
                    width: geometry.size.width,
                    height: geometry.size.height,
                    alignment: .top
                )
                .clipped()
        }
        .background(ProductPalette.pageBackground)
        .navigationTitle("Chat")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if store.hasConversation {
                    Button("New Chat", systemImage: "square.and.pencil", action: resetConversation)
                        .help(store.isLive
                            ? "Start a new conversation"
                            : "Start a new preview conversation")
                }
            }
        }
        .onDisappear(perform: stopResponse)
        .accessibilityElement(children: .contain)
    }

    private var chatSurface: some View {
        VStack(spacing: 0) {
            Group {
                if store.hasConversation {
                    conversation
                } else {
                    ScrollView {
                        ChatEmptyState(
                            identity: identity,
                            route: store.route,
                            detailOverride: store.isLive
                                ? "Everything you send runs on \(identity.displayName) through the local endpoint — nothing leaves this Mac."
                                : nil,
                            onSelectSuggestion: submit
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 42)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
            .clipped()

            if let failure = store.failure {
                ChatFailureNotice(
                    failure: failure,
                    onRetry: lastUserPrompt.map { prompt in { submit(prompt) } },
                    onDismiss: store.clearFailure
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            VStack(spacing: 0) {
                Divider()
                ChatComposer(
                    draft: $draft,
                    route: Binding(
                        get: { store.route },
                        set: { store.route = $0 }
                    ),
                    isResponding: store.isResponding,
                    isFocused: $composerIsFocused,
                    availableRoutes: store.isLive ? [.thisMac] : ChatRoute.allCases,
                    noteOverride: store.isLive ? liveComposerNote : nil,
                    onSubmit: { submit(draft) },
                    onStop: stopResponse
                )
            }
            .background(.bar)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var liveComposerNote: String {
        if let model = store.activeModelID {
            return "On this Mac · \(model) via the local endpoint"
        }
        return "On this Mac · the local endpoint picks the model"
    }

    private var lastUserPrompt: String? {
        store.messages.last(where: { $0.role == .user })?.text
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 22) {
                    ForEach(store.messages) { message in
                        ChatMessageView(message: message)
                            .id(message.id)
                    }

                    if store.isResponding {
                        ChatResponseIndicator(isLive: store.isLive)
                            .id("responding")
                    }
                }
                .frame(maxWidth: 720)
                .padding(.horizontal, 30)
                .padding(.vertical, 30)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: store.messages.count) { _, _ in
                scrollToLatest(using: proxy)
            }
            .onChange(of: store.lastMessageText) { _, _ in
                scrollToLatest(using: proxy)
            }
            .onChange(of: store.isResponding) { _, _ in
                scrollToLatest(using: proxy)
            }
        }
    }

    private func submit(_ rawPrompt: String) {
        guard let prompt = store.beginResponse(to: rawPrompt) else {
            composerIsFocused = true
            return
        }

        draft = ""
        responseTask?.cancel()
        responseTask = Task { @MainActor in
            if store.isLive {
                await store.respondLive(to: prompt)
            } else {
                if !reduceMotion {
                    try? await Task.sleep(for: .milliseconds(620))
                }
                guard !Task.isCancelled else { return }
                store.completeResponse(to: prompt)
            }
            guard !Task.isCancelled else { return }
            responseTask = nil
            composerIsFocused = true
        }
    }

    private func stopResponse() {
        responseTask?.cancel()
        responseTask = nil
        store.stopResponse()
        composerIsFocused = true
    }

    private func resetConversation() {
        responseTask?.cancel()
        responseTask = nil
        store.reset()
        draft = ""
        composerIsFocused = true
    }

    private func scrollToLatest(using proxy: ScrollViewProxy) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
            if store.isResponding {
                proxy.scrollTo("responding", anchor: .bottom)
            } else if let lastMessage = store.messages.last {
                proxy.scrollTo(lastMessage.id, anchor: .bottom)
            }
        }
    }
}

private struct ChatResponseIndicator: View {
    var isLive: Bool = false

    private var label: String {
        isLive ? "Generating on this Mac…" : "Preparing a sample reply…"
    }

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.leading, 40)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}
