import SwiftUI

struct ModelCatalogOfflineBanner: View {
    let message: String
    let showingCachedResults: Bool
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .foregroundStyle(ProductPalette.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                    .font(.system(size: 12, weight: .semibold))
                if showingCachedResults {
                    Text("Showing the last catalog saved on this Mac.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Try Again", action: onRetry)
                .buttonStyle(.bordered)
        }
        .padding(14)
        .background(ProductPalette.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .stroke(ProductPalette.warning.opacity(0.18), lineWidth: 1)
        }
    }
}
