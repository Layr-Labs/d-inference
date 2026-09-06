import SwiftUI

struct ChatEmptyState: View {
    let identity: MachineIdentity
    let route: ChatRoute
    var detailOverride: String? = nil
    let onSelectSuggestion: (String) -> Void

    private let suggestions = [
        ChatPromptSuggestion(
            title: "Explain something", prompt: "Explain unified memory in plain language, with an example.",
            systemImage: "lightbulb"
        ),
        ChatPromptSuggestion(
            title: "Work through code", prompt: "Help me understand this code and suggest improvements:\n\n",
            systemImage: "chevron.left.forwardslash.chevron.right"
        ),
        ChatPromptSuggestion(
            title: "Turn notes into a plan", prompt: "Turn these notes into a clear, prioritized plan:\n\n",
            systemImage: "checklist"
        ),
        ChatPromptSuggestion(
            title: "Compare approaches", prompt: "Compare these two approaches. Explain the tradeoffs and when to choose each:\n\n",
            systemImage: "arrow.triangle.branch"
        ),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(DarkbloomTheme.accent)
                .accessibilityHidden(true)

            Text("A place to think things through.")
                .font(.system(size: 28, weight: .semibold))
                .tracking(-0.6)
                .fixedSize(horizontal: false, vertical: true)

            Text(detail)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            Text("Try a starting point, then make it your own.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 14)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                ForEach(suggestions) { suggestion in
                    Button { onSelectSuggestion(suggestion.prompt) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: suggestion.systemImage)
                                .foregroundStyle(DarkbloomTheme.accent)
                                .frame(width: 20)
                            Text(suggestion.title)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(ProductPalette.elevatedSurface, in: RoundedRectangle(cornerRadius: 10))
                        .overlay { RoundedRectangle(cornerRadius: 10).stroke(ProductPalette.stroke) }
                    }
                    .buttonStyle(.plain)
                    .help("Add this prompt to the composer to edit before sending")
                }
            }
        }
        .frame(maxWidth: 650, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity)
    }

    private var detail: String {
        if let detailOverride { return detailOverride }
        return switch route {
        case .thisMac:
            "Explore the chat experience on \(identity.displayName). This is a preview; replies are samples and no model runs."
        case .privateNetwork:
            "Explore a sample network conversation. This preview does not encrypt, route, or run a model."
        }
    }
}

private struct ChatPromptSuggestion: Identifiable {
    let title: String
    let prompt: String
    let systemImage: String
    var id: String { prompt }
}
