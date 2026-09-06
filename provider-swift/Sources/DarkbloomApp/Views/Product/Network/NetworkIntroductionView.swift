import SwiftUI

struct NetworkIntroductionView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("The Darkbloom network")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(StudioPalette.accent)
            HStack(alignment: .top, spacing: 30) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Private AI.\nPowered by Macs.")
                        .font(DarkbloomTheme.chivo(38))
                        .tracking(-1.3)
                        .accessibilityAddTraits(.isHeader)
                    Text("Darkbloom connects apps that need AI with Macs that provide the compute. Use models across the network, or contribute this Mac when you choose.")
                        .font(.system(size: 14))
                        .foregroundStyle(StudioPalette.secondaryInk)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 570, alignment: .leading)
                    Link(destination: AccountSessionManager.defaultConsoleBaseURL) {
                        Label("Use network AI in the web console", systemImage: "arrow.up.right")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(StudioPalette.accent)
                    .help("Open the Darkbloom network console in your browser")
                }
                Spacer(minLength: 0)
                Image(systemName: "network")
                    .font(.system(size: 70, weight: .ultraLight))
                    .foregroundStyle(StudioPalette.accent)
                    .frame(width: 132, height: 132)
                    .background(StudioPalette.accentSoft, in: RoundedRectangle(cornerRadius: 32))
                    .accessibilityHidden(true)
            }

        }
    }
}
