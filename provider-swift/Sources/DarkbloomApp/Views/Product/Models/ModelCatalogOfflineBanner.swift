import SwiftUI

struct ModelCatalogOfflineBanner: View {
    let message: String
    let showingCachedResults: Bool
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "wifi.slash")
                .foregroundStyle(StudioPalette.secondaryInk)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(StudioPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(showingCachedResults
                     ? "Showing the saved catalog. Reconnect before downloading."
                     : "Reconnect to browse and download models.")
                    .font(.system(size: 12))
                    .foregroundStyle(StudioPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Try Again", action: onRetry)
                .buttonStyle(.bordered)
                .fixedSize()
        }
        .padding(14)
        .background(StudioPalette.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(StudioPalette.line, lineWidth: 1)
        }
    }
}
