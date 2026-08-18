import SwiftUI

struct SidebarProviderStatus: View {
    let snapshot: ProviderSnapshot

    private var presentation: ProviderStatusPresentation {
        snapshot.statusPresentation
    }

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(presentation.tint)
                .frame(width: 8, height: 8)
                .shadow(color: presentation.tint.opacity(0.35), radius: 3)

            VStack(alignment: .leading, spacing: 1) {
                Text(presentation.sidebarTitle)
                    .font(.system(size: 11, weight: .semibold))
                Text(presentation.sidebarDetail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Provider status")
        .accessibilityValue("\(presentation.sidebarTitle), \(presentation.sidebarDetail)")
    }
}
