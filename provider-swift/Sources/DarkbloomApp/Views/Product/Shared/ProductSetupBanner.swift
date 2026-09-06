import SwiftUI

/// A first visit can be useful before the Mac has joined the network.
/// This notice keeps setup discoverable without inventing a ready runtime.
struct ProductSetupBanner: View {
    let onContinue: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .foregroundStyle(DarkbloomTheme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Make yourself at home")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text("Try local AI now. Finish setup to share your Mac on the network.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("Set up this Mac", action: onContinue)
                .buttonStyle(.borderedProminent)
                .fixedSize()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }
}
