import Foundation

enum ChatSessionMode: Equatable {
    case fixture
    case live

    static func resolve(isPreview: Bool) -> Self {
        isPreview ? .fixture : .live
    }
}

/// Session history is held in memory by the injected store. No prompts are
/// written to disk. Keeping that store at shell scope preserves it on navigation.
struct ChatConversation: Identifiable {
    let id: UUID
    let messages: [LocalChatMessage]
    let draft: String
    let route: ChatRoute
    let selectedModelID: String?
    let failure: ChatFailure?
    let retryUserMessageID: UUID?

    var title: String {
        let text = messages.first(where: { $0.role == .user })?.text ?? draft
        return String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(70))
    }
}

enum ChatConnectionState: Equatable {
    case unchecked
    case checking
    /// The catalog advertises availability; it does not prove model residency.
    case available
    case unavailable(ChatFailure)
}
