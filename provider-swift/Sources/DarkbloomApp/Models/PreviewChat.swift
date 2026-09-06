import Foundation

enum PreviewChatFixture: String, Sendable {
    case empty
    case conversation

    var messages: [LocalChatMessage] {
        switch self {
        case .empty:
            []
        case .conversation:
            [
                LocalChatMessage(
                    role: .user,
                    text: "Explain unified memory in plain language."
                ),
                LocalChatMessage(
                    role: .assistant,
                    text: PreviewChatResponse.text(
                        for: "Explain unified memory in plain language.",
                        route: .thisMac
                    ),
                    isPreview: true
                ),
            ]
        }
    }
}

enum PreviewChatResponse {
    static func text(for prompt: String, route: ChatRoute) -> String {
        let subject = prompt
            .split(whereSeparator: \Character.isWhitespace)
            .prefix(12)
            .joined(separator: " ")
        let excerpt = subject.count < prompt.count ? "\(subject)…" : subject

        switch route {
        case .thisMac:
            return """
            This is a sample reply to “\(excerpt)”.

            When local inference is connected, Darkbloom will run the selected model on this Mac and stream its real response into this conversation. Nothing was sent and no model ran for this preview.
            """
        case .privateNetwork:
            return """
            This is a sample network reply to “\(excerpt)”.

            When network inference is connected, Darkbloom will encrypt and route the request before streaming the real response here. Nothing was encrypted, routed, or inferred for this preview.
            """
        }
    }
}
