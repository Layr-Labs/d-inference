import SwiftUI

/// The empty state *is* the working surface: title, live editor, then starters.
/// The same draft binding is used here and below an active conversation.
struct ChatEmptyState<Workspace: View>: View {
    let compact: Bool
    let onSelectSuggestion: (String) -> Void
    private let workspace: Workspace

    init(
        compact: Bool,
        onSelectSuggestion: @escaping (String) -> Void,
        @ViewBuilder workspace: () -> Workspace
    ) {
        self.compact = compact
        self.onSelectSuggestion = onSelectSuggestion
        self.workspace = workspace()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 24 : 32) {
            HStack(alignment: .center, spacing: 24) {
                Text("Room for an idea.")
                    .font(DarkbloomTheme.chivo(compact ? 46 : 62, weight: .medium))
                    .tracking(compact ? -1.8 : -2.6)
                    .foregroundStyle(StudioPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                StudioPresence()
            }

            VStack(alignment: .leading, spacing: 18) {
                workspace
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 28) { starters }
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)],
                    alignment: .leading, spacing: 16
                ) { starters }
            }
        }
        .frame(maxWidth: 840, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private var starters: some View {
        ForEach(ChatPromptStarter.all) { starter in
            Button(starter.title) { onSelectSuggestion(starter.prompt) }
                .buttonStyle(.borderless)
                .font(DarkbloomTheme.chivo(13))
                .foregroundStyle(StudioPalette.secondaryInk)
                .help("Add this starting point to your draft. Edit it before sending.")
        }
    }
}

private struct ChatPromptStarter: Identifiable {
    let title: String
    let prompt: String
    var id: String { title }

    static let all = [
        Self(title: "Shape an idea", prompt: "Help me develop this idea. Ask useful questions and suggest a direction:\n\n"),
        Self(title: "Work through code", prompt: "Help me understand this code and suggest improvements:\n\n"),
        Self(title: "Make a plan", prompt: "Turn these notes into a clear, prioritized plan:\n\n"),
        Self(title: "Explain something", prompt: "Explain unified memory in plain language, with an example."),
    ]
}
