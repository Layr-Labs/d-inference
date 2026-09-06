import SwiftUI

struct MyMacsPageHeader: View {
    let lastUpdated: Date?
    let isPreview: Bool
    let isRefreshing: Bool
    let canRefresh: Bool
    let canLink: Bool
    let onRefresh: () -> Void
    let onLink: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 20) {
                title
                Spacer(minLength: 12)
                actions
            }
            .frame(minWidth: 560)
            VStack(alignment: .leading, spacing: 12) {
                title
                actions
            }
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your Macs")
                .font(DarkbloomTheme.chivo(36))
                .tracking(-1.2)
                .accessibilityAddTraits(.isHeader)
            Text(isPreview ? "Sample fleet · UI preview" : "Macs linked to your account")
                .font(.body)
                .foregroundStyle(.secondary)
            if let lastUpdated {
                Text("\(isPreview ? "Sample updated" : "Updated") \(lastUpdated.formatted(date: .abbreviated, time: .shortened))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if isRefreshing {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Refreshing linked Macs")
            }
            if lastUpdated != nil {
                Button(isRefreshing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise", action: onRefresh)
                    .disabled(!canRefresh)
            }
            if canLink {
                Button("Link a Mac", systemImage: "plus", action: onLink)
                    .buttonStyle(StudioPrimaryButtonStyle())
            }
        }
        .fixedSize()
    }
}
