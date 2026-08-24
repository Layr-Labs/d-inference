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

    static func messageLabel(_ message: LocalChatMessage) -> String {
        switch (message.role, message.isPreview) {
        case (.user, true): "Your preview message"
        case (.assistant, true): "Simulated response"
        case (.user, false): "Your message"
        case (.assistant, false): "Darkbloom response"
        }
    }
}
