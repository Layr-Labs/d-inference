import Foundation

enum ChatPresentation {
    static func submitHint(isLive: Bool) -> String {
        isLive
            ? "Press Return to send this message to the local endpoint"
            : "Press Return to send this preview message"
    }

    static func sendLabel(isLive: Bool) -> String {
        isLive ? "Send message" : "Send preview message"
    }

    static func stopLabel(isLive: Bool) -> String {
        isLive ? "Stop response" : "Stop sample reply"
    }

    static func messageLabel(_ message: LocalChatMessage, isLive: Bool) -> String {
        switch message.role {
        case .user:
            isLive ? "Your message" : "Your preview message"
        case .assistant:
            isLive ? "Darkbloom response" : "Simulated response"
        }
    }
}
