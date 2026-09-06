import SwiftUI

struct ChatMessageView: View {
    let message: LocalChatMessage
    let isLive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(message.role == .user ? "You" : "Darkbloom")
                    .font(DarkbloomTheme.chivo(12, weight: .medium))
                    .foregroundStyle(message.role == .user ? StudioPalette.secondaryInk : StudioPalette.accent)
                if let model = message.modelID {
                    Text(model)
                        .foregroundStyle(StudioPalette.secondaryInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .font(DarkbloomTheme.chivo(12))

            ChatMessageBody(text: message.text, rendersMarkdown: message.role == .assistant)
                .font(DarkbloomTheme.chivo(message.role == .user ? 22 : 15, weight: message.role == .user ? .medium : .regular))
                .foregroundStyle(StudioPalette.ink)
                .lineSpacing(6)
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
            .foregroundStyle(StudioPalette.secondaryInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ChatPresentation.messageLabel(message, isLive: isLive))
    }
}
