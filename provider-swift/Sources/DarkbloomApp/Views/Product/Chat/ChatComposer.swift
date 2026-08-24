import SwiftUI

struct ChatComposer: View {
    @Binding var draft: String
    @Binding var route: ChatRoute
    let isResponding: Bool
    let isLive: Bool
    var isFocused: FocusState<Bool>.Binding
    /// Selectable routes; live stores restrict this to `.thisMac` because
    /// network routing isn't a live surface yet (honesty over symmetry).
    var availableRoutes: [ChatRoute] = ChatRoute.allCases
    /// Overrides the small status line next to the route picker (live
    /// surfaces report the real endpoint instead of preview copy).
    var noteOverride: String? = nil
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
                    .accessibilityHint(ChatPresentation.submitHint(isLive: isLive))

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
                    ForEach(availableRoutes) { option in
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
                .disabled(isResponding || availableRoutes.count <= 1)

                Text(noteOverride ?? route.previewNote)
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
            .help(ChatPresentation.stopLabel(isLive: isLive))
            .accessibilityLabel(ChatPresentation.stopLabel(isLive: isLive))
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
            .help(ChatPresentation.sendLabel(isLive: isLive))
            .accessibilityLabel(ChatPresentation.sendLabel(isLive: isLive))
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
