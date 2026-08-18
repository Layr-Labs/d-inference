import Foundation
import Observation

@MainActor
@Observable
final class PreviewChatStore {
    private(set) var messages: [LocalChatMessage]
    private(set) var isResponding = false
    var route: ChatRoute

    init(
        messages: [LocalChatMessage] = [],
        route: ChatRoute = .thisMac
    ) {
        self.messages = messages
        self.route = route
    }

    convenience init(fixture: PreviewChatFixture) {
        self.init(messages: fixture.messages)
    }

    var hasConversation: Bool {
        !messages.isEmpty
    }

    @discardableResult
    func beginResponse(to rawPrompt: String) -> String? {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isResponding else { return nil }

        messages.append(LocalChatMessage(role: .user, text: prompt))
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
    }

    func stopResponse() {
        isResponding = false
    }

    func reset() {
        messages.removeAll()
        isResponding = false
    }
}
