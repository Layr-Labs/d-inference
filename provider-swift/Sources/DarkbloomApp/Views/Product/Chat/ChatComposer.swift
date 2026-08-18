import SwiftUI

struct ChatComposer: View {
    @Binding var draft: String
    @Binding var route: ChatRoute
    let isResponding: Bool
    var isFocused: FocusState<Bool>.Binding
    let onSubmit: () -> Void
    let onStop: () -> Void

    private var draftIsEmpty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message Darkbloom", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...5)
                    .focused(isFocused)
                    .onSubmit(onSubmit)
                    .accessibilityHint("Press Return to send this preview message")

                sendOrStopButton
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(ProductPalette.elevatedSurface)
                    .shadow(
                        color: isFocused.wrappedValue
                            ? DarkbloomTheme.accent.opacity(0.10)
                            : .clear,
                        radius: 16,
                        y: 5
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(
                        isFocused.wrappedValue
                            ? DarkbloomTheme.accent.opacity(0.34)
                            : ProductPalette.stroke,
                        lineWidth: 1
                    )
            }

            HStack(spacing: 8) {
                Menu {
                    ForEach(ChatRoute.allCases) { option in
                        Button {
                            route = option
                        } label: {
                            Label(option.title, systemImage: option.systemImage)
                        }
                    }
                } label: {
                    Label(route.title, systemImage: route.systemImage)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(isResponding)

                Text(route.previewNote)
                    .lineLimit(1)

                Spacer()

                Text("Return to send")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
        .frame(maxWidth: 720)
        .padding(.horizontal, 28)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var sendOrStopButton: some View {
        if isResponding {
            Button(action: onStop) {
                composerButtonIcon("stop.fill", tint: DarkbloomTheme.accent)
            }
            .buttonStyle(.plain)
            .help("Stop sample reply")
            .accessibilityLabel("Stop sample reply")
        } else {
            Button(action: onSubmit) {
                composerButtonIcon(
                    "arrow.up",
                    tint: draftIsEmpty
                        ? Color.secondary.opacity(0.30)
                        : DarkbloomTheme.accent
                )
            }
            .buttonStyle(.plain)
            .disabled(draftIsEmpty)
            .keyboardShortcut(.return, modifiers: [.command])
            .help("Send preview message")
            .accessibilityLabel("Send preview message")
        }
    }

    private func composerButtonIcon(_ systemImage: String, tint: Color) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(tint, in: Circle())
    }
}
