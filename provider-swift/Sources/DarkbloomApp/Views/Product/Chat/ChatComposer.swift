import SwiftUI

struct ChatComposer: View {
    @Binding var draft: String
    @Binding var route: ChatRoute
    @Binding var isFocused: Bool
    let conversationID: UUID
    let isResponding: Bool
    let isLive: Bool
    let canSend: Bool
    var availableRoutes: [ChatRoute] = ChatRoute.allCases
    let onSubmit: () -> Void
    let onStop: () -> Void

    private var draftIsEmpty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 12) {
                ZStack(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text(isResponding ? "Write your next message…" : "Message Darkbloom…")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    ChatTextEditor(
                        text: $draft, isFocused: $isFocused,
                        conversationID: conversationID, onSubmit: submit
                    )
                    .id(conversationID)
                }
                .frame(maxWidth: .infinity)

                sendOrStopButton
            }
            .padding(14)
            .background(ProductPalette.elevatedSurface, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isFocused ? DarkbloomTheme.accent.opacity(0.55) : ProductPalette.stroke)
            }

            ViewThatFits(in: .horizontal) {
                HStack {
                    routeLabel
                    Spacer(minLength: 16)
                    keyboardHint
                }
                VStack(alignment: .leading, spacing: 5) {
                    routeLabel
                    keyboardHint
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 3)
        }
        .frame(maxWidth: 780)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
    }

    private var keyboardHint: some View {
        Text("Return to send · Shift-Return for a new line")
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var routeLabel: some View {
        if isLive {
            Label("Local to this Mac", systemImage: "desktopcomputer")
        } else {
            Menu {
                ForEach(availableRoutes) { option in
                    Button(option.title) { route = option }
                }
            } label: {
                Label("\(route.title) · Preview", systemImage: route.systemImage)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(isResponding)
        }
    }

    @ViewBuilder
    private var sendOrStopButton: some View {
        if isResponding {
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.bordered)
            .help(ChatPresentation.stopLabel(isLive: isLive))
            .accessibilityLabel(ChatPresentation.stopLabel(isLive: isLive))
        } else {
            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.borderedProminent)
            .tint(DarkbloomTheme.accent)
            .disabled(draftIsEmpty || !canSend)
            .help(ChatPresentation.sendLabel(isLive: isLive))
            .accessibilityLabel(ChatPresentation.sendLabel(isLive: isLive))
        }
    }

    private func submit() {
        guard canSend, !isResponding, !draftIsEmpty else { return }
        onSubmit()
    }
}
