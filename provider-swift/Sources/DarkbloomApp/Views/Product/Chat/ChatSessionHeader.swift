import SwiftUI

struct ChatSessionHeader: View {
    let isLive: Bool
    let connection: ChatConnectionState
    let availableModelIDs: [String]
    @Binding var selectedModelID: String?
    let isResponding: Bool
    let history: [ChatConversation]
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
        .font(.system(size: 13))
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var connectionLabel: some View {
        if !isLive {
            Label("Preview · no model runs", systemImage: "eye")
                .foregroundStyle(.secondary)
        } else {
            switch connection {
            case .unchecked, .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Connecting to local chat…")
                }
                .foregroundStyle(.secondary)
            case .available:
                Label("Local chat available", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            case .unavailable(let failure):
                Label(failure == .noModels ? "No model available" : "Local chat disconnected",
                      systemImage: "exclamationmark.circle")
                    .foregroundStyle(ProductPalette.warning)
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
                        .frame(maxWidth: 240)
                }
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
            .disabled(history.isEmpty)
            .help("Return to a previous conversation. History is kept in memory for this app session.")
            .accessibilityLabel("Chat history, \(history.count) conversations")
        }
        .controlSize(.small)
    }
}
