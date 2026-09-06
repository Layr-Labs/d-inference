import SwiftUI

struct MenuBarPreviewDisclosure: View {
    var body: some View {
        Text("Sample local and network status. Runtime controls are disabled in this preview.")
            .font(DarkbloomTheme.chivo(11))
            .foregroundStyle(StudioPalette.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
    }
}
