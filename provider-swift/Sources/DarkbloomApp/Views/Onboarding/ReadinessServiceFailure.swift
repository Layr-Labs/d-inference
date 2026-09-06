import SwiftUI

/// A failed diagnostics process is not a failed hardware check.
struct ReadinessServiceFailure: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 25))
                .foregroundStyle(ProductPalette.warning)
                .accessibilityHidden(true)
            Text("The system check couldn’t run")
                .font(.system(size: 17, weight: .semibold))
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Your Mac’s compatibility hasn’t been determined yet. You can retry this check or return to explore the app.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
