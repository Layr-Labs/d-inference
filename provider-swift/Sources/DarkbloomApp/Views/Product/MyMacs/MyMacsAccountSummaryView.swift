import SwiftUI

struct MyMacsAccountSummaryView: View {
    let summary: MyMacsAccountSummary?
    let availability: MyMacsSummaryAvailability
    let onOpenContributions: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Across all Macs")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Account totals, not estimates for the selected Mac")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let summary {
                    Button(action: onOpenContributions) {
                        HStack(spacing: 7) {
                            VStack(alignment: .trailing, spacing: 1) {
                                Text("Recent account activity")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(
                                    "\(summary.last24HoursEarnings.formattedUSD()) · " +
                                        "\(summary.last24HoursJobs.formatted()) jobs"
                                )
                                .font(.caption.weight(.medium))
                            }
                            Image(systemName: "arrow.up.right")
                                .font(.caption2.weight(.semibold))
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Open account Contributions")
                }
            }

            Divider()

            switch (summary, availability) {
            case let (.some(summary), _):
                ViewThatFits(in: .horizontal) {
                    metricLine(summary)
                        .frame(minWidth: 560)
                    VStack(alignment: .leading, spacing: 12) {
                        metricPair(
                            first: ("Linked", summary.counts.total.formatted()),
                            second: (
                                "Connected",
                                (summary.counts.online + summary.counts.serving).formatted()
                            )
                        )
                        metricPair(
                            first: ("Serving", summary.counts.serving.formatted()),
                            second: ("Needs attention", summary.counts.needingAttention.formatted())
                        )
                    }
                }

            case let (.none, .unavailable(message)):
                Label(message, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

            case (.none, .available):
                Label("Account totals were not reported.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .productSurface()
    }

    private func metricLine(_ summary: MyMacsAccountSummary) -> some View {
        HStack(spacing: 0) {
            metric(label: "Linked", value: summary.counts.total.formatted())
            divider
            metric(
                label: "Connected",
                value: (summary.counts.online + summary.counts.serving).formatted()
            )
            divider
            metric(label: "Serving", value: summary.counts.serving.formatted())
            divider
            metric(
                label: "Needs attention",
                value: summary.counts.needingAttention.formatted(),
                emphasized: summary.counts.needingAttention > 0
            )
        }
    }

    private func metricPair(
        first: (String, String),
        second: (String, String)
    ) -> some View {
        HStack(spacing: 0) {
            metric(label: first.0, value: first.1)
            divider
            metric(label: second.0, value: second.1)
        }
    }

    private func metric(label: String, value: String, emphasized: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.7)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(emphasized ? ProductPalette.warning : Color.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    private var divider: some View {
        Divider()
            .frame(height: 34)
            .padding(.horizontal, 14)
    }
}
