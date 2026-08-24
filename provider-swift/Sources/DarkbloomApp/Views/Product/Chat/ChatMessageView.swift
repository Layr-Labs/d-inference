import SwiftUI

struct ChatMessageView: View {
    let message: LocalChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.role == .assistant {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DarkbloomTheme.accent)
                    .frame(width: 28, height: 28)
                    .background(DarkbloomTheme.accent.opacity(0.10), in: Circle())
            } else {
                Spacer(minLength: 52)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 5) {
                Text(message.text)
                    .font(.system(size: 13))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(
                        message.role == .user
                            ? DarkbloomTheme.accent.opacity(0.10)
                            : ProductPalette.surface,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )

                if message.isPreview {
                    Text("PREVIEW RESPONSE")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                }
            }

            if message.role == .assistant {
                Spacer(minLength: 52)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ChatPresentation.messageLabel(message))
        .accessibilityValue(message.text)
    }
}
