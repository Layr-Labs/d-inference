import SwiftUI

struct ContributionBalanceHero: View {
    let snapshot: ContributionsSnapshot
    let onRequestPayout: () -> Void

    private var canRequestPayout: Bool {
        snapshot.payoutReadiness == .ready &&
            snapshot.withdrawableBalance >= snapshot.minimumPayout
    }

    var body: some View {
        HStack(alignment: .center, spacing: 30) {
            VStack(alignment: .leading, spacing: 0) {
                Label("WITHDRAWABLE", systemImage: "circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.9)
                    .foregroundStyle(DarkbloomTheme.accent)
                    .labelStyle(ContributionHeroLabelStyle())

                Text(ContributionsPresentation.amount(snapshot.withdrawableBalance))
                    .font(.system(size: 42, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .tracking(-1.4)
                    .padding(.top, 12)

                Text("of \(ContributionsPresentation.amount(snapshot.availableBalance)) available")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)
            }

            Spacer(minLength: 18)

            VStack(alignment: .trailing, spacing: 10) {
                payoutStatus

                Button {
                    onRequestPayout()
                } label: {
                    Label(
                        snapshot.payoutReadiness == .setupRequired
                            ? "Review payout readiness"
                            : "Preview withdrawal",
                        systemImage: snapshot.payoutReadiness == .setupRequired
                            ? "person.crop.circle.badge.plus"
                            : "arrow.up.right"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(
                    snapshot.payoutReadiness == .ready &&
                        snapshot.withdrawableBalance < snapshot.minimumPayout
                )

                Text(minimumPayoutDetail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 24)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(ProductPalette.elevatedSurface)
                .overlay {
                    LinearGradient(
                        colors: [
                            DarkbloomTheme.accent.opacity(0.11),
                            DarkbloomTheme.nodePale.opacity(0.045),
                            .clear,
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(ProductPalette.stroke, lineWidth: 1)
                }
        }
        .accessibilityElement(children: .contain)
    }

    private var payoutStatus: some View {
        Group {
            if snapshot.payoutReadiness == .setupRequired {
                ProductStatusBadge(
                    title: "Payouts not ready",
                    systemImage: "exclamationmark.circle.fill",
                    tint: ProductPalette.warning
                )
            } else if canRequestPayout {
                ProductStatusBadge(
                    title: "Ready to withdraw",
                    systemImage: "checkmark.circle.fill",
                    tint: ProductPalette.positive
                )
            } else {
                ProductStatusBadge(
                    title: "Still blooming",
                    systemImage: "leaf.fill",
                    tint: DarkbloomTheme.accent
                )
            }
        }
    }

    private var minimumPayoutDetail: String {
        if snapshot.payoutReadiness == .setupRequired {
            return "Payouts need attention before you can withdraw"
        }
        if canRequestPayout {
            return "UI preview only — no money will move"
        }
        return "Minimum withdrawal: \(ContributionsPresentation.amount(snapshot.minimumPayout))"
    }
}

private struct ContributionHeroLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            configuration.icon
                .font(.system(size: 6))
            configuration.title
        }
    }
}
