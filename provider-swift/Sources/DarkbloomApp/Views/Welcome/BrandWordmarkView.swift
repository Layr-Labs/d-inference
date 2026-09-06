import SwiftUI

struct BrandWordmarkView: View {
    var color = DarkbloomTheme.ink

    var body: some View {
        Text("Darkbloom")
            .font(DarkbloomTheme.chivo(20))
            .tracking(-0.6)
            .foregroundStyle(color)
            .accessibilityLabel("Darkbloom")
    }
}
