import SwiftUI

/// Local sessions have their own process and endpoint lifecycle. The network
/// daemon snapshot cannot establish whether local AI is running.
struct LocalAIOverviewCard: View {
    let isPreview: Bool
    let onOpenChat: () -> Void
    let onOpenLocalAPI: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProductSectionHeader("For you")
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 25))
                        .foregroundStyle(DarkbloomTheme.accent)
                    Spacer()
                    ProductStatusBadge(title: "On this Mac", systemImage: "desktopcomputer", tint: .secondary)
                }
                Text("Private AI on this Mac")
                    .font(.system(size: 16, weight: .semibold))
                    .padding(.top, 18)
                Text(isPreview
                     ? "Explore the Chat preview or see how to connect your own client."
                     : "Chat with a local model or connect your own client. Choose a model and manage its endpoint in Local API.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .padding(.top, 5)
                HStack(spacing: 12) {
                    Button("Open Local API", systemImage: "arrow.right", action: onOpenLocalAPI)
                    Button(isPreview ? "Preview Chat" : "Open Chat", action: onOpenChat)
                }
                .buttonStyle(.link)
                .padding(.top, 20)
            }
            .padding(17)
            .productSurface()
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
