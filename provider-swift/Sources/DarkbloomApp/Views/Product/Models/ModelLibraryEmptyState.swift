import SwiftUI

struct ModelLibraryEmptyState: View {
    let onExplore: () -> Void

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: "shippingbox")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            Text("No models on this Mac yet")
                .font(.system(size: 14, weight: .semibold))
            Text("Explore compatible models and Darkbloom will verify every download before use.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("Explore models", action: onExplore)
                .buttonStyle(.borderedProminent)
                .padding(.top, 5)
        }
        .frame(maxWidth: .infinity, minHeight: 190)
        .productSurface()
    }
}
