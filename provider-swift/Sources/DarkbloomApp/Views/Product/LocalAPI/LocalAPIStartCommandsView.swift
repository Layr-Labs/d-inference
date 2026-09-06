import SwiftUI

struct LocalAPIStartCommandsView: View {
    let store: LocalAPIStore
    let copiedItem: LocalAPICopyItem?
    let onCopy: (LocalAPICopyItem) -> Void
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup("Advanced: Terminal commands", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 18) {
                Text("These commands are alternatives to the native controls. Stop any existing provider through its controls before changing modes.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                commandRow(
                    mode: .unified,
                    title: "Local + network",
                    detail: "Serve local clients and private network work from the same provider process."
                )

                Divider()

                commandRow(
                    mode: .directOnly,
                    title: "Local only",
                    detail: "Run a coordinator-free foreground server for direct requests on this Mac."
                )
            }
            .padding(.top, 12)
        }
        .padding(.vertical, 20)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func commandRow(mode: LocalAPIMode, title: String, detail: String) -> some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(store.text(for: .command(mode)) ?? mode.startCommand)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(ProductPalette.surface)
                .overlay { Rectangle().stroke(ProductPalette.stroke, lineWidth: 1) }

            Button {
                onCopy(.command(mode))
            } label: {
                Label(
                    copiedItem == .command(mode) ? "Copied" : "Copy command",
                    systemImage: copiedItem == .command(mode) ? "checkmark" : "doc.on.doc"
                )
            }
            .buttonStyle(.bordered)
        }
    }
}
