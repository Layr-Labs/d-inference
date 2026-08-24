import Foundation
import Observation
import ProviderCoreFoundation

/// How the live chat store reaches a real endpoint: discovery record →
/// client, current model → request. All three seams are injectable so tests
/// never touch the network or the real `~/.darkbloom`.
struct LiveChatConfiguration: Sendable {
    /// Reads the local-endpoint discovery record per send, so the store
    /// follows the endpoint appearing/disappearing between messages.
    var discoveryReader: @Sendable () -> LocalEndpointInfo?

    /// Picks the model id for the request. Defaults to the daemon-state
    /// file's `currentModel` — the same truth `ProviderStore` renders (the
    /// ownership boundary keeps the chat view from reaching across stores).
    /// When it returns nil the store falls back to the endpoint's first
    /// reported model (`GET /models`).
    var modelProvider: @Sendable () -> String?

    /// Resolves PID + kernel start identity immediately before any request.
    /// A PID-only existence check could send the bearer token or prompt to an
    /// unrelated process after PID reuse.
    var processIdentityReader: @Sendable (Int32) -> ProcessIdentity?

    var clientFactory: @Sendable (LocalEndpointInfo) -> LocalEndpointClient

    init(
        discoveryReader: @escaping @Sendable () -> LocalEndpointInfo? = {
            LocalEndpointDiscovery.readInfo()
        },
        modelProvider: @escaping @Sendable () -> String? = {
            DaemonStateFile.read()?.currentModel
        },
        processIdentityReader: @escaping @Sendable (Int32) -> ProcessIdentity? = {
            ProcessIdentity.read(pid: $0)
        },
        clientFactory: @escaping @Sendable (LocalEndpointInfo) -> LocalEndpointClient = { info in
            LocalEndpointClient(info: info)
        }
    ) {
        self.discoveryReader = discoveryReader
        self.modelProvider = modelProvider
        self.processIdentityReader = processIdentityReader
        self.clientFactory = clientFactory
    }
}

struct ChatFailure: Equatable, Sendable {
    var title: String
    var detail: String

    static func from(_ error: LocalEndpointError) -> ChatFailure {
        switch error {
        case .invalidEndpoint:
            ChatFailure(
                title: "The local endpoint address is invalid",
                detail: "The discovery record in ~/.darkbloom does not describe a usable URL. Restart the provider from the Overview to repair it."
            )
        case .unreachable, .httpError:
            ChatFailure(
                title: "The local endpoint did not respond",
                detail: "Start the provider from the Overview, then send again."
            )
        }
    }

    static let noDiscovery = ChatFailure(
        title: "The provider is offline",
        detail: "Start the provider from the Overview, then send again."
    )

    static let untrustedDiscovery = ChatFailure(
        title: "The local endpoint record is stale",
        detail: "Restart the provider from the Overview before sending private prompts."
    )

    static let noModels = ChatFailure(
        title: "The local endpoint serves no models",
        detail: "Add a model from the Models page or choose one when starting the provider, then send again."
    )
}

@MainActor
@Observable
final class PreviewChatStore {
    private(set) var messages: [LocalChatMessage]
    private(set) var isResponding = false
    /// Actionable, user-dismissable failure from a live send; nil in
    /// fixture mode (previews never fail).
    private(set) var failure: ChatFailure?
    /// The model id the live store used for the most recent send.
    private(set) var activeModelID: String?
    var route: ChatRoute

    private let live: LiveChatConfiguration?
    private var responseUserMessageID: UUID?

    init(
        messages: [LocalChatMessage] = [],
        route: ChatRoute = .thisMac
    ) {
        self.messages = messages
        self.route = route
        self.live = nil
    }

    convenience init(fixture: PreviewChatFixture) {
        self.init(messages: fixture.messages)
    }

    /// Live store driven by the real local endpoint. Streaming, errors, and
    /// cancellation behave; `route` only shapes preview responses — live
    /// sends always go to this Mac's local endpoint regardless of route, so
    /// live surfaces restrict the picker to `.thisMac`.
    init(live configuration: LiveChatConfiguration) {
        self.messages = []
        self.route = .thisMac
        self.live = configuration
    }

    var hasConversation: Bool {
        !messages.isEmpty
    }

    var isLive: Bool { live != nil }

    /// Observed by the conversation view to scroll on every streamed token
    /// (message replacement preserves identity, so `messages.count` alone
    /// never fires during streaming).
    var lastMessageText: String {
        messages.last?.text ?? ""
    }

    @discardableResult
    func beginResponse(to rawPrompt: String) -> String? {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isResponding else { return nil }

        let message = LocalChatMessage(role: .user, text: prompt)
        messages.append(message)
        responseUserMessageID = message.id
        failure = nil
        isResponding = true
        return prompt
    }

    /// Re-run the failed turn without appending its user message again.
    /// Partial assistant output belongs to the failed attempt and is removed
    /// before the same user-message identity is sent again.
    @discardableResult
    func retryLastFailedResponse() -> String? {
        guard failure != nil, !isResponding else { return nil }
        guard let responseUserMessageID,
              let userIndex = messages.firstIndex(where: {
                  $0.id == responseUserMessageID && $0.role == .user
              })
        else {
            failure = nil
            self.responseUserMessageID = nil
            return nil
        }

        if userIndex < messages.index(before: messages.endIndex) {
            messages.removeSubrange(messages.index(after: userIndex)...)
        }
        let prompt = messages[userIndex].text
        guard !prompt.isEmpty else {
            failure = nil
            self.responseUserMessageID = nil
            return nil
        }
        failure = nil
        isResponding = true
        return prompt
    }

    func completeResponse(to prompt: String) {
        guard isResponding else { return }
        messages.append(LocalChatMessage(
            role: .assistant,
            text: PreviewChatResponse.text(for: prompt, route: route),
            isPreview: true
        ))
        isResponding = false
        failure = nil
        responseUserMessageID = nil
    }

    // MARK: - Live streaming

    /// Send the conversation to the local endpoint and stream the reply into
    /// an appended assistant message. `beginResponse(to:)` must have run
    /// first (the view's submit pipeline owns that).
    ///
    /// Cancellation (the composer's stop button, view disappearance) keeps
    /// the partial reply without surfacing an error. Transport and HTTP
    /// failures keep whatever streamed so far and surface an actionable
    /// `failure`; an empty assistant placeholder is removed either way.
    func respondLive(to _: String) async {
        guard isResponding, let live else { return }
        failure = nil

        guard let info = live.discoveryReader() else {
            isResponding = false
            failure = .noDiscovery
            return
        }
        guard LocalEndpointRuntimeTruth.belongsToLiveProcess(
            info,
            readIdentity: live.processIdentityReader
        ) else {
            isResponding = false
            failure = .untrustedDiscovery
            return
        }
        let client = live.clientFactory(info)

        guard let model = await resolveModel(configuration: live, client: client) else {
            isResponding = false
            return
        }
        // Model fallback may have awaited an authenticated `/models` request.
        // Revalidate before the first request that carries plaintext prompts.
        guard LocalEndpointRuntimeTruth.belongsToLiveProcess(
            info,
            readIdentity: live.processIdentityReader
        ) else {
            isResponding = false
            failure = .untrustedDiscovery
            return
        }
        activeModelID = model

        let wire = messages.map {
            LocalEndpointClient.ChatMessage(
                role: $0.role == .user ? "user" : "assistant",
                content: $0.text
            )
        }

        let assistantID = UUID()
        messages.append(LocalChatMessage(id: assistantID, role: .assistant, text: ""))

        do {
            for try await delta in client.streamChat(model: model, messages: wire) {
                // A delta already buffered by the stream can be delivered
                // after the consumer task is cancelled — without this guard
                // the transcript keeps growing past an explicit stop.
                if Task.isCancelled { break }
                appendContent(delta.content, to: assistantID)
            }
        } catch is CancellationError {
            // User stop: keep the partial reply, no failure banner.
        } catch let error as URLError where error.code == .cancelled {
            // Session-level cancellation on view disappear: same treatment.
        } catch let error as LocalEndpointError {
            failure = .from(error)
        } catch {
            failure = .from(.unreachable(error.localizedDescription))
        }

        dropMessageIfEmpty(assistantID)
        isResponding = false
        if failure == nil {
            responseUserMessageID = nil
        }
    }

    /// Model id for the request: the provider's current model if any,
    /// otherwise the endpoint's first reported model. Failures land in
    /// `failure` and return nil.
    private func resolveModel(
        configuration: LiveChatConfiguration,
        client: LocalEndpointClient
    ) async -> String? {
        if let model = configuration.modelProvider(), !model.isEmpty {
            return model
        }
        do {
            let ids = try await client.listModels()
            guard let first = ids.first else {
                failure = .noModels
                return nil
            }
            return first
        } catch let error as LocalEndpointError {
            failure = .from(error)
            return nil
        } catch {
            failure = .from(.unreachable(error.localizedDescription))
            return nil
        }
    }

    // MARK: - Lifecycle

    func stopResponse() {
        if isLive {
            // Cancellation keeps partial replies; drop only an untouched
            // placeholder so a stop-before-first-token leaves no empty bubble.
            if let last = messages.last, last.role == .assistant, last.text.isEmpty {
                messages.removeLast()
            }
        }
        isResponding = false
        responseUserMessageID = nil
    }

    func reset() {
        messages.removeAll()
        isResponding = false
        failure = nil
        responseUserMessageID = nil
    }

    func clearFailure() {
        failure = nil
        responseUserMessageID = nil
    }

    // MARK: - Streaming helpers

    private func appendContent(_ content: String, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let existing = messages[index]
        messages[index] = LocalChatMessage(
            id: existing.id,
            role: existing.role,
            text: existing.text + content,
            isPreview: existing.isPreview
        )
    }

    private func dropMessageIfEmpty(_ id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }),
              messages[index].text.isEmpty
        else { return }
        messages.remove(at: index)
    }
}
