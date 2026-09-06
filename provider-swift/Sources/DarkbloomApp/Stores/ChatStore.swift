import Foundation
import Observation

/// Conversation state for both real local chat and deterministic UI fixtures.
/// The shell can own and inject one store to retain drafts/history on navigation.
@MainActor
@Observable
final class ChatStore {
    private(set) var messages: [LocalChatMessage]
    private(set) var isResponding = false
    private(set) var failure: ChatFailure?
    private(set) var activeModelID: String?
    private(set) var connection: ChatConnectionState = .unchecked
    private(set) var availableModelIDs: [String] = []
    private(set) var history: [ChatConversation] = []
    private(set) var conversationID = UUID()
    var draft = ""
    var route: ChatRoute
    var selectedModelID: String?

    private let live: LiveChatConfiguration?
    private var responseUserMessageID: UUID?
    /// Every attempt gets a distinct identity, including retries of one turn.
    /// Late catalog results, deltas and errors must never mutate a newer attempt.
    private var responseID: UUID?
    private var responseModelID: String?
    private var connectionCheckID: UUID?

    init(messages: [LocalChatMessage] = [], route: ChatRoute = .thisMac) {
        self.messages = messages
        self.route = route
        self.live = nil
    }

    convenience init(fixture: PreviewChatFixture) {
        self.init(messages: fixture.messages)
    }

    init(live configuration: LiveChatConfiguration) {
        self.messages = []
        self.route = .thisMac
        self.live = configuration
    }

    var hasConversation: Bool { !messages.isEmpty }
    var isLive: Bool { live != nil }
    var lastMessageText: String { messages.last?.text ?? "" }
    var canStartNewChat: Bool { hasConversation || !draft.isEmpty }
    var canRetry: Bool { failure != nil && responseUserMessageID != nil && !isResponding }
    var modelSelectionFailure: ChatFailure? {
        guard isLive, connection == .available, let selectedModelID,
              !availableModelIDs.contains(selectedModelID)
        else { return nil }
        return .selectedModelUnavailable
    }
    var canSend: Bool {
        guard !isResponding else { return false }
        guard isLive else { return true }
        switch connection {
        case .available: return modelSelectionFailure == nil
        case .unchecked, .checking, .unavailable: return false
        }
    }

    /// Read-only catalog check: never starts serving, loads a model or sends a
    /// prompt. Failure here is separate from the failed turn's retry state.
    func refreshConnection() async {
        guard !Task.isCancelled, let live, !isResponding else { return }
        let checkID = UUID()
        connectionCheckID = checkID
        connection = .checking
        do {
            let endpoint = try ChatEndpointSession(configuration: live, probe: true)
            let models = try await endpoint.client.listModels()
            try endpoint.validate()
            guard connectionCheckID == checkID else { return }
            guard !models.isEmpty else { throw ChatFailure.noModels }
            availableModelIDs = models
            // Only an unselected session gets a default. Never replace an
            // explicit choice just because it disappeared from the catalog.
            if selectedModelID == nil || selectedModelID?.isEmpty == true {
                let preferred = live.modelProvider()
                selectedModelID = preferred.flatMap { models.contains($0) ? $0 : nil } ?? models.first
            }
            connection = .available
        } catch {
            guard connectionCheckID == checkID else { return }
            if Task.isCancelled {
                connection = .unchecked
            } else {
                availableModelIDs = []
                connection = .unavailable(ChatEndpointSession.failure(for: error))
            }
        }
        if connectionCheckID == checkID { connectionCheckID = nil }
    }

    @discardableResult
    func beginResponse(to rawPrompt: String) -> String? {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isResponding else { return nil }
        let message = LocalChatMessage(role: .user, text: prompt)
        messages.append(message)
        responseUserMessageID = message.id
        beginAttempt()
        return prompt
    }

    /// Retry keeps the failed user's identity and removes only the assistant
    /// output from that attempt, avoiding duplicate prompts in the wire history.
    @discardableResult
    func retryLastFailedResponse() -> String? {
        guard canRetry, let responseUserMessageID,
              let index = messages.firstIndex(where: {
                  $0.id == responseUserMessageID && $0.role == .user
              })
        else { return nil }
        let prompt = messages[index].text
        messages.removeSubrange(messages.index(after: index)..<messages.endIndex)
        beginAttempt()
        return prompt
    }

    private func beginAttempt() {
        connectionCheckID = nil
        if connection == .checking { connection = .unchecked }
        responseID = UUID()
        // Bind the user-selected model to this attempt before its task starts.
        // Changing selection for the next turn cannot retarget an accepted send.
        responseModelID = selectedModelID
        failure = nil
        isResponding = true
    }

    func completeResponse(to prompt: String) {
        guard !isLive, isResponding,
              messages.last?.id == responseUserMessageID,
              messages.last?.text == prompt
        else { return }
        messages.append(LocalChatMessage(
            role: .assistant,
            text: PreviewChatResponse.text(for: prompt, route: route),
            isPreview: true
        ))
        finishAttempt()
    }

    /// The view cancels its task on Stop/disappear. Attempt identity also fences
    /// results from transports that ignore cancellation or have buffered output.
    func respondLive(to _: String) async {
        guard !Task.isCancelled, isResponding, let live, let attemptID = responseID else { return }
        var assistantID: UUID?
        do {
            let endpoint = try ChatEndpointSession(configuration: live)
            let resolved = try await endpoint.resolveModel(selectedModelID: responseModelID)
            guard responseID == attemptID else { return }
            try endpoint.validate() // Recheck PID/start identity after any await, before plaintext POST.
            let model = resolved.id
            availableModelIDs = resolved.catalog
            activeModelID = model
            connection = .available
            let wire = messages.map {
                LocalEndpointClient.ChatMessage(
                    role: $0.role == .user ? "user" : "assistant", content: $0.text
                )
            }
            let id = UUID()
            assistantID = id
            messages.append(LocalChatMessage(id: id, role: .assistant, text: "", modelID: model))
            for try await delta in endpoint.client.streamChat(model: model, messages: wire) {
                guard responseID == attemptID else { return }
                try Task.checkCancellation()
                appendContent(delta.content, to: id)
            }
        } catch {
            guard responseID == attemptID else { return }
            if Task.isCancelled || error is CancellationError
                || (error as? URLError)?.code == .cancelled {
                markInterrupted(assistantID, reason: .stopped)
            } else {
                let issue = ChatEndpointSession.failure(for: error)
                failure = issue
                if issue == .noDiscovery || issue == .untrustedDiscovery || issue == .noModels {
                    connection = .unavailable(issue)
                }
                markInterrupted(assistantID, reason: .failed)
            }
        }
        guard responseID == attemptID else { return }
        if Task.isCancelled { markInterrupted(assistantID, reason: .stopped) }
        dropEmptyAssistant(assistantID)
        finishAttempt()
    }

    func stopResponse() {
        guard isResponding else { return }
        if messages.last?.role == .assistant {
            let id = messages.last?.id
            markInterrupted(id, reason: .stopped)
            dropEmptyAssistant(id)
        }
        responseID = nil
        responseModelID = nil
        isResponding = false
        responseUserMessageID = nil
    }

    /// New Chat preserves both the transcript and any unsent draft in history.
    /// It keeps the chosen model/route for the next experiment.
    func reset() {
        stopResponse()
        archiveCurrentConversation()
        messages = []
        draft = ""
        failure = nil
        responseUserMessageID = nil
        activeModelID = nil
        conversationID = UUID()
    }

    func restoreConversation(_ id: UUID) {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        stopResponse()
        let saved = history.remove(at: index)
        archiveCurrentConversation()
        conversationID = saved.id
        messages = saved.messages
        draft = saved.draft
        route = saved.route
        selectedModelID = saved.selectedModelID
        failure = saved.failure
        responseUserMessageID = saved.retryUserMessageID
        activeModelID = messages.last(where: { $0.role == .assistant })?.modelID
    }

    func clearFailure() {
        failure = nil
        responseUserMessageID = nil
    }

    private func archiveCurrentConversation() {
        guard canStartNewChat else { return }
        history.insert(ChatConversation(
            id: conversationID, messages: messages, draft: draft, route: route,
            selectedModelID: selectedModelID, failure: failure,
            retryUserMessageID: responseUserMessageID
        ), at: 0)
    }

    private func finishAttempt() {
        isResponding = false
        responseID = nil
        responseModelID = nil
        if failure == nil { responseUserMessageID = nil }
    }

    private func appendContent(_ content: String, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let message = messages[index]
        messages[index] = LocalChatMessage(
            id: message.id, role: message.role, text: message.text + content,
            isPreview: message.isPreview, modelID: message.modelID,
            interruption: message.interruption
        )
    }

    private func markInterrupted(_ id: UUID?, reason: LocalChatMessage.Interruption) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].interruption = reason
    }

    private func dropEmptyAssistant(_ id: UUID?) {
        guard let index = messages.firstIndex(where: { $0.id == id }),
              messages[index].role == .assistant, messages[index].text.isEmpty
        else { return }
        messages.remove(at: index)
    }
}
