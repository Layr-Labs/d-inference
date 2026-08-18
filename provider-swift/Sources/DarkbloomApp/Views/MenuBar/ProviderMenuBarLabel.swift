import SwiftUI

struct ProviderMenuBarLabelPresentation: Equatable, Sendable {
    let systemImage: String
    let accessibilityLabel: String

    init(content: ProviderMenuBarContent) {
        switch content {
        case .setup:
            systemImage = "circle.dashed"
            accessibilityLabel = "Darkbloom, setup incomplete"
        case .provider(let snapshot):
            let status = snapshot.statusPresentation
            systemImage = status.icon
            accessibilityLabel = "Darkbloom, \(status.sidebarTitle)"
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
