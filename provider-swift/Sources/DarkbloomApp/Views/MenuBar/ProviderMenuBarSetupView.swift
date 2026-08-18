import SwiftUI

struct ProviderMenuBarSetupView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Finish setting up this Mac")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Complete the guided setup before provider status or controls appear here.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "circle.dashed")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(DarkbloomTheme.accent)
            }

            Button(action: onContinue) {
                Label("Continue Setup…", systemImage: "arrow.up.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}
