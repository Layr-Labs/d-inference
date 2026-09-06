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
    var isProminent = false
    let onSubmit: () -> Void
    let onStop: () -> Void

    private var draftIsEmpty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 12) {
                ZStack(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text(isResponding ? "Write your next message…" : "An idea, a question, a first draft…")
                            .font(.system(size: 15))
                            .foregroundStyle(StudioPalette.secondaryInk)
                            .padding(.top, 4)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    ChatTextEditor(
                        text: $draft, isFocused: $isFocused,
                        conversationID: conversationID,
                        minimumHeight: isProminent ? 104 : 58, onSubmit: submit
                    )
                    .id(conversationID)
                }
                .frame(maxWidth: .infinity, minHeight: isProminent ? 104 : 58, alignment: .topLeading)

                sendOrStopButton
            }
            .padding(isProminent ? 20 : 16)
            .background {
                RoundedRectangle(cornerRadius: 20)
                    .fill(StudioPalette.surface)
                    .onTapGesture { isFocused = true }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .stroke(isFocused ? StudioPalette.accent : StudioPalette.line, lineWidth: isFocused ? 1.5 : 1)
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
            .foregroundStyle(StudioPalette.secondaryInk)
            .padding(.horizontal, 3)
        }
    }

    private var keyboardHint: some View {
        Text("Return to send   ⇧ Return for a new line")
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var routeLabel: some View {
        if isLive {
            Text("Private to this Mac")
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
                    .frame(width: 16, height: 24)
            }
            .buttonStyle(StudioPrimaryButtonStyle())
            .help(ChatPresentation.stopLabel(isLive: isLive))
            .accessibilityLabel(ChatPresentation.stopLabel(isLive: isLive))
        } else {
            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 16, height: 24)
            }
            .buttonStyle(StudioPrimaryButtonStyle())
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
