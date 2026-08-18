import SwiftUI

struct ChatEmptyState: View {
    let identity: MachineIdentity
    let route: ChatRoute
    let onSelectSuggestion: (String) -> Void

    private let suggestions = [
        ChatPromptSuggestion(
            title: "Explain unified memory",
            prompt: "Explain unified memory in plain language.",
            systemImage: "memorychip"
        ),
        ChatPromptSuggestion(
            title: "Turn notes into a plan",
            prompt: "Turn my rough notes into a clear, prioritized plan.",
            systemImage: "checklist"
        ),
        ChatPromptSuggestion(
            title: "Draft a thoughtful reply",
            prompt: "Help me draft a concise, thoughtful reply.",
            systemImage: "text.bubble"
        ),
        ChatPromptSuggestion(
            title: "Compare two approaches",
            prompt: "Help me compare two approaches and make the tradeoffs clear.",
            systemImage: "arrow.triangle.branch"
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                SpatialFieldView(
                    presentation: .welcome,
                    focus: 0.42,
                    pointer: CGPoint(x: 0.62, y: 0.48),
                    activity: 0.25
                )

                Image(systemName: identity.formFactor.symbolName)
                    .font(.system(size: 31, weight: .ultraLight))
                    .foregroundStyle(.black)
            }
            .frame(width: 104, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.78), lineWidth: 1)
            }
            .shadow(color: DarkbloomTheme.accent.opacity(0.14), radius: 20, y: 9)

            Text("Start with a thought.")
                .font(DarkbloomTheme.chivo(26))
                .tracking(-0.55)
                .padding(.top, 17)

            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 490)
                .padding(.top, 7)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 215), spacing: 10)],
                spacing: 10
            ) {
                ForEach(suggestions) { suggestion in
                    Button {
                        onSelectSuggestion(suggestion.prompt)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: suggestion.systemImage)
                                .foregroundStyle(DarkbloomTheme.accent)
                                .frame(width: 16)

                            Text(suggestion.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.primary)

                            Spacer()

                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 13)
                        .padding(.vertical, 12)
                        .productSurface()
                    }
                    .buttonStyle(.plain)
                    .help("Send this sample prompt")
                }
            }
            .frame(maxWidth: 540)
            .padding(.top, 24)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 24)
    }

    private var detail: String {
        switch route {
        case .thisMac:
            "Type a message or try a prompt below. This UI preview stays on \(identity.displayName); no model runs yet."
        case .privateNetwork:
            "Try the future network conversation flow. This UI preview does not encrypt, route, or run a model."
        }
    }
}

private struct ChatPromptSuggestion: Identifiable {
    let title: String
    let prompt: String
    let systemImage: String

    var id: String { prompt }
}
