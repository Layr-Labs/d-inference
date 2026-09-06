import SwiftUI

/// Quiet, expandable supporting information below the connection workspace.
struct LocalAPIDisclosure<Content: View>: View {
    let title: String
    let content: Content

    @State private var isExpanded = false

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 14)
        } label: {
            Text(title)
                .font(DarkbloomTheme.chivo(16, weight: .medium))
                .foregroundStyle(StudioPalette.ink)
        }
        .tint(StudioPalette.accent)
        .padding(.vertical, 15)
        .overlay(alignment: .bottom) {
            Rectangle().fill(StudioPalette.line).frame(height: 1)
        }
    }
}

/// Copy still goes through the owning view and LocalAPIStore.text(for:).
struct LocalAPICopyButton: View {
    let title: String
    let item: LocalAPICopyItem
    let copiedItem: LocalAPICopyItem?
    let onCopy: (LocalAPICopyItem) -> Void

    private var isCopied: Bool { copiedItem == item }

    var body: some View {
        Button {
            onCopy(item)
        } label: {
            Label(isCopied ? "Copied" : title, systemImage: isCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12, weight: .medium))
                .fixedSize()
        }
        .buttonStyle(.borderless)
        .foregroundStyle(StudioPalette.accent)
        .help(isCopied ? item.confirmation : title)
        .accessibilityLabel(isCopied ? item.confirmation : title)
    }
}
