import SwiftUI

/// Account totals stay separate from the selected machine's report, including
/// when the fleet is empty after a removal or a refresh retains older data.
struct MyMacsAccountSummaryView: View {
    let summary: MyMacsAccountSummary?
    let availability: MyMacsSummaryAvailability
    let onOpenContributions: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            if let summary {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 16) {
                        counts(summary)
                        Spacer(minLength: 12)
                        earnings(summary)
                    }
                    .frame(minWidth: 650)
                    VStack(alignment: .leading, spacing: 10) {
                        counts(summary)
                        earnings(summary)
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Account totals unavailable").font(.body.weight(.medium))
                        Text(unavailableMessage).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Across all Macs, account totals")
    }

    private func counts(_ summary: MyMacsAccountSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Across all Macs").font(.body.weight(.semibold))
            Text("\(summary.counts.total.formatted()) linked · \((summary.counts.online + summary.counts.serving).formatted()) connected · \(summary.counts.needingAttention.formatted()) need attention")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func earnings(_ summary: MyMacsAccountSummary) -> some View {
        Button(action: onOpenContributions) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(summary.last24HoursEarnings.formattedUSD()) · \(summary.last24HoursJobs.formatted()) jobs")
                        .font(.body.weight(.medium)).monospacedDigit()
                    Text("Account activity · last 24 hours")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Image(systemName: "arrow.up.right").font(.callout)
            }
        }
        .buttonStyle(.plain)
        .help("Open account Contributions")
    }

    private var unavailableMessage: String {
        switch availability {
        case let .unavailable(message): message
        case .available: "Account totals were not reported."
        }
    }
}
