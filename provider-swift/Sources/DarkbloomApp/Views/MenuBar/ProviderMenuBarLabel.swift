import SwiftUI

struct ProviderMenuBarLabelPresentation: Equatable, Sendable {
    let systemImage: String
    let accessibilityLabel: String

    init(content: ProviderMenuBarContent) {
        systemImage = "sparkle"
        switch content {
        case .setup:
            accessibilityLabel = "Darkbloom, network setup required"
        case .provider(let snapshot):
            accessibilityLabel = "Darkbloom network, \(ProviderMenuBarNetworkPresentation(snapshot: snapshot).title)"
        }
    }
}

struct ProviderMenuBarLabel: View {
    let content: ProviderMenuBarContent

    var body: some View {
        let presentation = ProviderMenuBarLabelPresentation(content: content)

        Image(systemName: presentation.systemImage)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.primary)
            .accessibilityLabel(presentation.accessibilityLabel)
            .help(presentation.accessibilityLabel)
    }
}
