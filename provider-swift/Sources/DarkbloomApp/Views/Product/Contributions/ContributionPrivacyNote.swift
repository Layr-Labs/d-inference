import SwiftUI

struct ContributionPrivacyNote: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProductSectionHeader("What this view shows")

            VStack(spacing: 14) {
                fact(
                    icon: "number",
                    title: "Accounting metadata",
                    detail: "Mac, model, time, token counts, and earned amount."
                )

                Divider()

                fact(
                    icon: "eye.slash.fill",
                    title: "Never conversation content",
                    detail: "Prompts and responses do not appear in this ledger."
                )

                Divider()

                fact(
                    icon: "checkmark.seal.fill",
                    title: "Completed work only",
                    detail: "Each row represents a finished accounting event."
                )
            }
            .padding(.top, 15)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
    }

    private func fact(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DarkbloomTheme.accent)
                .frame(width: 26, height: 26)
                .background(DarkbloomTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
