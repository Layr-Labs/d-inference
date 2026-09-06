import SwiftUI

struct ChatSessionHeader: View {
    let isLive: Bool
    let connection: ChatConnectionState
    let availableModelIDs: [String]
    @Binding var selectedModelID: String?
    let isResponding: Bool
    let history: [ChatConversation]
    let canStartNewChat: Bool
    let onNewChat: () -> Void
    let onRestore: (UUID) -> Void
    let onRefresh: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                connectionLabel
                Spacer(minLength: 12)
                controls
            }
            VStack(alignment: .leading, spacing: 10) {
                connectionLabel
                HStack { controls; Spacer(minLength: 0) }
            }
        }
        .font(DarkbloomTheme.chivo(12))
        .foregroundStyle(StudioPalette.secondaryInk)
    }

    @ViewBuilder
    private var connectionLabel: some View {
        if !isLive {
            Text("Preview. No model runs.")
                .foregroundStyle(StudioPalette.secondaryInk)
        } else {
            switch connection {
            case .unchecked, .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking this Mac…")
                }
                .foregroundStyle(StudioPalette.secondaryInk)
            case .available:
                Label("On this Mac", systemImage: "circle.fill")
                    .labelStyle(ChatConnectionLabelStyle())
                    .foregroundStyle(StudioPalette.secondaryInk)
            case .unavailable(let failure):
                Text(failure == .noModels ? "Choose a local model" : "Local model offline")
                    .foregroundStyle(StudioPalette.secondaryInk)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if isLive, !availableModelIDs.isEmpty {
                Menu {
                    ForEach(availableModelIDs, id: \.self) { model in
                        Button {
                            selectedModelID = model
                        } label: {
                            if selectedModelID == model {
                                Label(model, systemImage: "checkmark")
                            } else {
                                Text(model)
                            }
                        }
                    }
                } label: {
                    Text(selectedModelID ?? "Choose a model")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 190)
                }
                .menuStyle(.borderlessButton)
                .disabled(isResponding)
                .help("Choose a model advertised by the local endpoint. It may load when you send.")
                .accessibilityLabel("Chat model")
                .accessibilityValue(selectedModelID ?? "Not selected")
            }

            if isLive {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(isResponding || connection == .checking)
                .help("Check the local chat connection")
                .accessibilityLabel("Check connection")
            }

            Menu {
                Text("Kept for this app session")
                ForEach(history) { conversation in
                    Button(conversation.title.isEmpty ? "Untitled draft" : conversation.title) {
                        onRestore(conversation.id)
                    }
                }
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(history.isEmpty)
            .help("Return to a previous conversation. History is kept in memory for this app session.")
            .accessibilityLabel("Chat history, \(history.count) conversations")

            Button("New chat", systemImage: "square.and.pencil", action: onNewChat)
                .buttonStyle(.borderless)
                .foregroundStyle(StudioPalette.ink)
                .keyboardShortcut("n", modifiers: [.command])
                .disabled(!canStartNewChat)
                .fixedSize()
                .help("New chat (⌘N). Keep this conversation and draft in History.")
        }
        .controlSize(.small)
    }
}

private struct ChatConnectionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            configuration.icon
                .font(.system(size: 5))
                .foregroundStyle(StudioPalette.accent)
                .accessibilityHidden(true)
            configuration.title
        }
    }
}
