import SwiftUI

struct ChatMessageView: View {
    let message: LocalChatMessage
    let isLive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: message.role == .user ? "person.crop.circle" : "sparkles")
                    .foregroundStyle(message.role == .user ? Color.secondary : DarkbloomTheme.accent)
                    .accessibilityHidden(true)
                Text(message.role == .user ? "You" : "Darkbloom")
                    .fontWeight(.semibold)
                if let model = message.modelID {
                    Text(model)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))

            ChatMessageBody(text: message.text, rendersMarkdown: message.role == .assistant)
                .font(.system(size: 15))
                .lineSpacing(5)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                if message.isPreview {
                    Text("Sample reply · no model ran")
                } else if let interruption = message.interruption {
                    Text(interruption == .stopped ? "Stopped · partial response kept" : "Interrupted · partial response kept")
                }
                Spacer(minLength: 0)
                ChatCopyButton(text: message.text, label: "Copy")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .padding(message.role == .user ? 16 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if message.role == .user {
                RoundedRectangle(cornerRadius: 12).fill(DarkbloomTheme.accent.opacity(0.07))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ChatPresentation.messageLabel(message, isLive: isLive))
    }
}
