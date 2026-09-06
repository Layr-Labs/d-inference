import SwiftUI

struct SidebarProviderStatus: View {
    let snapshot: ProviderSnapshot

    private var presentation: ProviderStatusPresentation {
        snapshot.statusPresentation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Network provider")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Circle()
                    .fill(presentation.tint)
                    .frame(width: 7, height: 7)
                Text(presentation.sidebarTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(presentation.sidebarDetail)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Network provider status")
        .accessibilityValue("\(presentation.sidebarTitle), \(presentation.sidebarDetail)")
    }
}
