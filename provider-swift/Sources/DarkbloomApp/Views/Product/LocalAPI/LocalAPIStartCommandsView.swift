import SwiftUI

struct LocalAPIStartCommandsView: View {
    let store: LocalAPIStore
    let copiedItem: LocalAPICopyItem?
    let onCopy: (LocalAPICopyItem) -> Void

    var body: some View {
        LocalAPIDisclosure("Terminal commands") {
            VStack(alignment: .leading, spacing: 18) {
                Text("Stop an existing provider through its controls before changing modes.")
                    .font(.system(size: 12))
                    .foregroundStyle(StudioPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)

                commandRow(
                    mode: .directOnly,
                    title: "Local only",
                    detail: "A foreground session for requests on this Mac."
                )
                commandRow(
                    mode: .unified,
                    title: "Local + network",
                    detail: "One provider for local clients and network work."
                )
            }
        }
    }

    private func commandRow(mode: LocalAPIMode, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(StudioPalette.ink)
                Spacer(minLength: 0)
                LocalAPICopyButton(
                    title: "Copy command", item: .command(mode),
                    copiedItem: copiedItem, onCopy: onCopy
                )
            }
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(StudioPalette.secondaryInk)

            ScrollView(.horizontal) {
                Text(store.text(for: .command(mode)) ?? mode.startCommand)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(StudioPalette.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(12)
            }
            .background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
