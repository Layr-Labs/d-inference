import SwiftUI

struct ContributionSummaryStrip: View {
    let snapshot: ContributionsSnapshot
    let scope: ContributionScope
    let shownRecordCount: Int
    let shownRecordTokens: UInt64

    var body: some View {
        HStack(spacing: 0) {
            metric(
                title: "Lifetime",
                value: ContributionsPresentation.amount(snapshot.earnedLifetime),
                detail: "account earnings"
            )
            divider
            metric(
                title: "Lifetime jobs",
                value: ContributionsPresentation.jobCount(snapshot.lifetimeJobs),
                detail: "account total"
            )
            divider
            metric(
                title: "Records shown",
                value: shownRecordCount.formatted(),
                detail: "bounded · \(scope.title)"
            )
            divider
            metric(
                title: "Tokens shown",
                value: ContributionsPresentation.tokenCount(shownRecordTokens),
                detail: "bounded · \(scope.title)"
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 17)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
    }

    private var divider: some View {
        Rectangle()
            .fill(ProductPalette.stroke)
            .frame(width: 1, height: 48)
    }

    private func metric(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.65)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(detail)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(value), \(detail)")
    }
}
